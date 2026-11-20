#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
CONFIG="$ROOT/config.local.yaml"

source "$SCRIPT_DIR/_common.sh"

echo "=== Tearing down MCP server (Container App) ==="
cd "$ROOT/infra"

# -target destroys only the Container App; ACR + CAE stay up until script 06.
# Terraform will print a "resource targeting" warning — that is expected here.
terraform destroy -auto-approve \
  -target="azapi_resource.ca" \
  -var="subscription_id=$SUBSCRIPTION_ID" \
  -var="tenant_id=$TENANT_ID" \
  -var="region=$REGION" \
  -var="image_tag=placeholder"

echo ""
echo "Container App destroyed."
echo "ACR and Container Apps environment are still up (run 06 to destroy everything)."

# Clear MCP URL from config
python3 - <<PYEOF
import yaml

config_path = "$CONFIG"
with open(config_path) as f:
    cfg = yaml.safe_load(f) or {}

cfg.setdefault("mcp", {})
cfg["mcp"]["url"] = "PLACEHOLDER"
cfg["mcp"]["api_key"] = "PLACEHOLDER"

with open(config_path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
print("Cleared mcp.url in config.local.yaml")
PYEOF
