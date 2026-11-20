#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
CONFIG="$ROOT/config.local.yaml"

source "$SCRIPT_DIR/_common.sh"

echo "=== Full teardown: Foundry + ACR + Container Apps ==="
cd "$ROOT/infra"

ACCOUNT_NAME=$(terraform output -raw foundry_account_name 2>/dev/null || echo "")
RG=$(terraform output -raw resource_group_name 2>/dev/null || echo "")

# Delete the resource group directly — Azure orders child deletions itself and
# runs them in parallel, which is much faster and more reliable than
# `terraform destroy` (which stalls on the Container Apps Environment).
# Set USE_TERRAFORM_DESTROY=1 to use the old behaviour as a fallback.

_fmt_elapsed() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

_rg_remaining() {
  local SUB TYPES
  SUB="$(az account show --query id -o tsv 2>/dev/null)" || return 0
  TYPES="$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/resources?api-version=2021-04-01" \
    --query "value[].type" -o tsv 2>/dev/null \
    | sed 's|.*/||' | sort -u | paste -sd, - | sed 's/,/, /g')"
  echo "${TYPES:-nothing listed (finalizing)}"
}

if [[ -z "$RG" ]]; then
  echo "No resource group name in Terraform state — nothing to delete."
elif ! az group show --name "$RG" --output none 2>/dev/null; then
  echo "Resource group $RG is already gone."
else
  if [[ "${USE_TERRAFORM_DESTROY:-0}" == "1" ]]; then
    echo "USE_TERRAFORM_DESTROY=1 — running terraform destroy first..."
    terraform destroy -auto-approve \
      -var="subscription_id=$SUBSCRIPTION_ID" \
      -var="tenant_id=$TENANT_ID" \
      -var="region=$REGION" \
      -var="image_tag=placeholder" \
      || echo "terraform destroy reported errors — continuing with resource group delete."
  fi

  echo "Requesting deletion of resource group $RG..."
  az group delete --name "$RG" --yes --no-wait

  _ELAPSED=0
  _MAX=1800  # 30 min hard timeout
  while az group show --name "$RG" --output none 2>/dev/null; do
    if (( _ELAPSED >= _MAX )); then
      echo ""
      echo "ERROR: $RG still exists after $(_fmt_elapsed $_MAX). The delete request is submitted."
      echo "  Re-run this script to keep waiting, or check the Azure portal."
      echo "  Remaining: $(_rg_remaining)"
      exit 1
    fi
    echo "  [$(_fmt_elapsed $_ELAPSED)] still deleting — remaining: $(_rg_remaining)"
    sleep 30
    _ELAPSED=$(( _ELAPSED + 30 ))
  done
  echo "Resource group $RG deleted."

  # The CAE quota (1 per region) counts resources in ScheduledForDelete too.
  # Wait until the old CAE fully disappears before returning, so the next
  # script 01 run doesn't hit MaxNumberOfRegionalEnvironmentsInSubExceeded.
  _ELAPSED=0
  while [[ -n "$(az containerapp env list \
      --query "[?location=='Sweden Central' && properties.provisioningState=='ScheduledForDelete'].name" \
      -o tsv 2>/dev/null)" ]]; do
    if (( _ELAPSED >= _MAX )); then
      echo "WARNING: CAE still in ScheduledForDelete after $(_fmt_elapsed $_MAX). Re-run script 06 or wait before running script 01."
      break
    fi
    echo "  [$(_fmt_elapsed $_ELAPSED)] CAE still draining (ScheduledForDelete)..."
    sleep 30
    _ELAPSED=$(( _ELAPSED + 30 ))
  done
  echo "CAE quota slot is free."
fi

# Clear Terraform state (bypassed destroy, so state still lists the old resources).
echo ""
echo "=== Clearing Terraform state ==="
terraform state list 2>/dev/null | xargs -r terraform state rm
echo "State cleared."

# ── Purge soft-deleted Cognitive Services account ─────────────────────────────
# Azure soft-deletes the account for 48h after destroy; purge to allow name reuse.
if [[ -n "$ACCOUNT_NAME" && -n "$REGION" ]]; then
  echo ""
  echo "=== Purging soft-deleted Cognitive Services account ==="
  az cognitiveservices account purge \
    --name "$ACCOUNT_NAME" \
    --location "$REGION" \
    --resource-group "$RG" 2>/dev/null && echo "Purged $ACCOUNT_NAME" || echo "Purge skipped (account may already be purged or not found)"
fi

# ── Reset config ──────────────────────────────────────────────────────────────
python3 - <<PYEOF
import yaml

config_path = "$CONFIG"
try:
    with open(config_path) as f:
        cfg = yaml.safe_load(f) or {}
except FileNotFoundError:
    cfg = {}

placeholder = "PLACEHOLDER"
cfg["foundry"] = {
    "resource_name": placeholder,
    "endpoint": placeholder,
    "project_endpoint": placeholder,
    "api_key": placeholder,
    "gpt_deployment": placeholder,
    "claude_deployment": placeholder,
}
cfg["mcp"] = {"url": placeholder, "api_key": placeholder}

with open(config_path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
print("config.local.yaml: foundry.* and mcp.* reset to placeholders. azure.* preserved.")
PYEOF

echo ""
echo "=== Teardown complete. All Azure resources destroyed. ==="
