#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
CONFIG="$ROOT/config.local.yaml"

source "$SCRIPT_DIR/_common.sh"

echo "=== Building and deploying MCP server ==="
cd "$ROOT/infra"

ACR_NAME=$(terraform output -raw acr_name)
ACR_LOGIN_SERVER=$(terraform output -raw acr_login_server)
RG=$(terraform output -raw resource_group_name)

echo ""
echo "=== Building container image via az acr build ==="
IMAGE_TAG=$(date +%Y%m%d%H%M%S)
az acr build \
  --registry "$ACR_NAME" \
  --image "mcp-server:$IMAGE_TAG" \
  "$ROOT/mcp_server"

echo ""
echo "=== Getting ACR credentials ==="
ACR_PASSWORD=$(az acr credential show \
  --name "$ACR_NAME" \
  --resource-group "$RG" \
  --query "passwords[0].value" -o tsv)

echo ""
echo "=== Terraform apply (Container App) ==="
# Inject ACR password into tfvars for the secret
export TF_VAR_acr_password="$ACR_PASSWORD"

terraform apply -auto-approve \
  -var="subscription_id=$SUBSCRIPTION_ID" \
  -var="tenant_id=$TENANT_ID" \
  -var="region=$REGION" \
  -var="image_tag=$IMAGE_TAG"

MCP_URL=$(terraform output -raw mcp_url)
MCP_API_KEY=$(terraform output -raw mcp_api_key)

echo ""
echo "=== Updating config.local.yaml with MCP config ==="
python3 - <<PYEOF
import yaml

config_path = "$CONFIG"
with open(config_path) as f:
    cfg = yaml.safe_load(f) or {}

cfg.setdefault("mcp", {})
cfg["mcp"]["url"] = "$MCP_URL"
cfg["mcp"]["api_key"] = "$MCP_API_KEY"

with open(config_path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)

print("config.local.yaml updated.")
PYEOF

echo ""
echo "=== MCP server deployed ==="
echo "  URL: $MCP_URL"
echo ""
echo "Next: ./scripts/03_status.sh"
