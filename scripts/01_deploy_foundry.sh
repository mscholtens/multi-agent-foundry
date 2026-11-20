#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
CONFIG="$ROOT/config.local.yaml"

# ── Prerequisites ─────────────────────────────────────────────────────────────
echo "=== Checking prerequisites ==="
command -v az >/dev/null || { echo "ERROR: az CLI not found"; exit 1; }
command -v terraform >/dev/null || { echo "ERROR: terraform not found"; exit 1; }
echo "OK"

# ── Auth (interactive or service principal) ───────────────────────────────────
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

# ── Terraform apply (Foundry + ACR + Container Apps env) ─────────────────────
echo ""
echo "=== Terraform apply (Foundry + ACR + Container Apps env) ==="
cd "$ROOT/infra"
terraform init -upgrade -input=false

# Purge any soft-deleted Foundry account left over from a previous run.
# Needed when the resource group was deleted externally (e.g. via portal) before
# script 06 had a chance to purge it — Azure blocks recreating the same name otherwise.
PREV_ACCOUNT=$(terraform output -raw foundry_account_name 2>/dev/null || echo "")
PREV_RG=$(terraform output -raw resource_group_name 2>/dev/null || echo "")
if [[ -n "$PREV_ACCOUNT" && -n "$PREV_RG" ]]; then
  echo "--- Purging soft-deleted Cognitive Services account (if any): $PREV_ACCOUNT ---"
  az cognitiveservices account purge \
    --name "$PREV_ACCOUNT" --location "$REGION" --resource-group "$PREV_RG" \
    2>/dev/null && echo "Purged." || echo "Nothing to purge (skipping)."
fi

terraform apply -auto-approve \
  -var="subscription_id=$SUBSCRIPTION_ID" \
  -var="tenant_id=$TENANT_ID" \
  -var="region=$REGION"

# ── Role assignments (az CLI — user session has Owner, SP has only Contributor) ─
echo ""
echo "=== Role assignments ==="
ACCOUNT_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$(terraform output -raw resource_group_name)/providers/Microsoft.CognitiveServices/accounts/$(terraform output -raw foundry_account_name)"

_assign_role() {
  local ROLE_ID="$1" LABEL="$2"
  az role assignment create \
    --role "$ROLE_ID" --assignee "$PRINCIPAL_ID" --scope "$ACCOUNT_SCOPE" \
    --output none 2>/dev/null \
    && echo "  Assigned: $LABEL" \
    || echo "  Already assigned (or skipped): $LABEL"
}
_assign_role "a97b65f3-24c7-4388-baec-2e87135dc908" "Cognitive Services User"
_assign_role "53ca6127-db72-4b80-b1b0-d745d6d5456d" "Foundry User"

# ── Claude deployment (always via CLI — modelProviderData requires JSON string) ─
echo ""
echo "=== Claude deployment ==="
ACCOUNT_NAME=$(terraform output -raw foundry_account_name)
RG=$(terraform output -raw resource_group_name)
CLAUDE_DEPLOYMENT="claude-haiku-5-5-deployment"

DEPLOYMENT_EXISTS=$(az cognitiveservices account deployment show \
  --name "$CLAUDE_DEPLOYMENT" \
  --account-name "$ACCOUNT_NAME" \
  --resource-group "$RG" \
  --query name -o tsv 2>/dev/null || echo "")

if [[ -z "$DEPLOYMENT_EXISTS" ]]; then
  CREATE_OUTPUT=$(az cognitiveservices account deployment create \
    --name "$ACCOUNT_NAME" \
    --resource-group "$RG" \
    --deployment-name "$CLAUDE_DEPLOYMENT" \
    --model-name "claude-haiku-5-5" \
    --model-format "Anthropic" \
    --model-version "1" \
    --sku "GlobalStandard" \
    --capacity 10 \
    --organization-name "Lab" \
    --industry "Technology" \
    --country "NL" 2>&1) || {
    if echo "$CREATE_OUTPUT" | grep -q "InsufficientQuota"; then
      echo ""
      echo "ERROR: No Claude Haiku 5.5 quota in this subscription/region."
      echo "  Request quota (usually instant) in the Azure AI Foundry portal:"
      echo "  portal.azure.com → search 'AI Foundry' → your account → Management → Quota"
      echo "  Then re-run this script."
    else
      echo "$CREATE_OUTPUT"
    fi
    exit 1
  }
  echo "Claude deployment created."
else
  echo "Claude deployment already exists."
fi

# ── Role assignments on account ───────────────────────────────────────────────
# ── Write config.local.yaml ───────────────────────────────────────────────────
echo ""
echo "=== Writing foundry config to config.local.yaml ==="

RESOURCE_NAME=$(terraform output -raw foundry_account_name)
ENDPOINT=$(terraform output -raw foundry_endpoint)
PROJECT_ENDPOINT=$(terraform output -raw foundry_project_endpoint)
GPT_DEPLOYMENT=$(terraform output -raw gpt_deployment_name)
CLAUDE_DEPLOYMENT=$(terraform output -raw claude_deployment_name)
# Azure Cognitive Services keys are not in the GET response — use listKeys via az CLI.
API_KEY=$(az cognitiveservices account keys list \
  --name "$RESOURCE_NAME" --resource-group "$RG" --query key1 -o tsv)

python3 - <<PYEOF
import yaml, os

config_path = "$CONFIG"
try:
    with open(config_path) as f:
        cfg = yaml.safe_load(f) or {}
except FileNotFoundError:
    cfg = {}

cfg.setdefault("azure", {})
cfg["azure"]["subscription_id"] = "$SUBSCRIPTION_ID"
cfg["azure"]["tenant_id"] = "$TENANT_ID"
cfg["azure"]["region"] = "$REGION"

cfg.setdefault("foundry", {})
cfg["foundry"]["resource_name"] = "$RESOURCE_NAME"
cfg["foundry"]["endpoint"] = "$ENDPOINT"
cfg["foundry"]["project_endpoint"] = "$PROJECT_ENDPOINT"
cfg["foundry"]["api_key"] = "$API_KEY"
cfg["foundry"]["gpt_deployment"] = "$GPT_DEPLOYMENT"
cfg["foundry"]["claude_deployment"] = "$CLAUDE_DEPLOYMENT"

cfg.setdefault("mcp", {"url": "PLACEHOLDER", "api_key": "PLACEHOLDER"})

with open(config_path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)

print("config.local.yaml updated.")
PYEOF

echo ""
echo "=== Foundry deployment complete ==="
echo "  Endpoint        : $ENDPOINT"
echo "  Project endpoint: $PROJECT_ENDPOINT"
echo "  GPT deployment  : $GPT_DEPLOYMENT"
echo "  Claude deployment: $CLAUDE_DEPLOYMENT"
echo ""
echo "Next: ./scripts/02_deploy_mcp_server.sh"
