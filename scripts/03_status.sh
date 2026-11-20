#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
CONFIG="$ROOT/config.local.yaml"

source "$SCRIPT_DIR/_common.sh"

echo "=== Status Check ==="
cd "$ROOT/infra"

RG=$(terraform output -raw resource_group_name 2>/dev/null || echo "")
if [[ -z "$RG" ]]; then
  echo "ERROR: No Terraform state found. Run 01_deploy_foundry.sh first."
  exit 1
fi

echo ""
echo "--- Foundry Account ---"
ACCOUNT_NAME=$(terraform output -raw foundry_account_name)
az cognitiveservices account show \
  --name "$ACCOUNT_NAME" \
  --resource-group "$RG" \
  --query "{name:name, state:properties.provisioningState, endpoint:properties.endpoint}" \
  -o table

echo ""
echo "--- Model Deployments ---"
az cognitiveservices account deployment list \
  --name "$ACCOUNT_NAME" \
  --resource-group "$RG" \
  --query "[].{name:name, model:properties.model.name, state:properties.provisioningState}" \
  -o table

echo ""
echo "--- Container App ---"
MCP_URL=$(read_yaml "['mcp']['url']")
if [[ -z "$MCP_URL" || "$MCP_URL" == "PLACEHOLDER" ]]; then
  echo "MCP server not yet deployed (run 02_deploy_mcp_server.sh)"
else
  SUFFIX=$(terraform output -raw foundry_account_name | sed 's/ai-maf-//')
  CA_NAME="ca-mcp-$SUFFIX"
  az containerapp show \
    --name "${CA_NAME}" \
    --resource-group "$RG" \
    --query "{name:name, fqdn:properties.configuration.ingress.fqdn, replicas:properties.template.scale.minReplicas, state:properties.provisioningState}" \
    -o table 2>/dev/null || echo "  (Could not retrieve Container App details)"

  echo ""
  echo "--- MCP Health Check ---"
  MCP_API_KEY=$(read_yaml "['mcp']['api_key']")
  # FastMCP 2.x requires initialize first (with Accept: text/event-stream).
  # tools/list without it returns 400.
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "x-api-key: $MCP_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -X POST "$MCP_URL" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"status-check","version":"1"}}}' \
    --max-time 10 || echo "000")

  if [[ "$HTTP_STATUS" == "200" ]]; then
    echo "  MCP server: OK (HTTP 200)"
  else
    echo "  MCP server: UNREACHABLE (HTTP $HTTP_STATUS) — $MCP_URL"
  fi
fi

echo ""
echo "=== Status check complete ==="
