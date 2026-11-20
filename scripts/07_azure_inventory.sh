#!/usr/bin/env bash
# Read-only inventory of all Azure resources created by multi-agent-foundry.
# Discovers resources by querying Azure directly — works whether deployed or torn down.
# Does NOT rely on Terraform state to find resources (state is shown at the end for comparison).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."

row() { printf "  %-32s %s\n" "$1:" "${2:-<none>}"; }

echo "=== Azure Inventory: multi-agent-foundry ==="
echo ""

# ── Resource groups ────────────────────────────────────────────────────────────

RGS=$(az group list \
  --query "[?starts_with(name, 'rg-maf-')].name" -o tsv 2>/dev/null || true)

if [[ -z "$RGS" ]]; then
  echo "No resource groups matching 'rg-maf-*' found — environment is clean."
  echo ""
else
  while IFS= read -r RG; do
    [[ -z "$RG" ]] && continue
    SUFFIX="${RG#rg-maf-}"

    RG_STATE=$(az group show --name "$RG" \
      --query "properties.provisioningState" -o tsv 2>/dev/null || echo "unknown")
    echo "Resource group: $RG  [$RG_STATE]"
    echo ""

    echo "  All resources:"
    az resource list \
      --resource-group "$RG" \
      --query "sort_by([].{Name:name, Type:type, State:properties.provisioningState}, &Type)" \
      -o table 2>/dev/null | sed 's/^/    /' || echo "    <cannot list>"
    echo ""

    echo "  Cognitive Services deployments:"
    az cognitiveservices account deployment list \
      --name "ai-maf-$SUFFIX" --resource-group "$RG" \
      --query "[].{Name:name, Model:properties.model.name, Format:properties.model.format, SKU:sku.name, Capacity:sku.capacity, State:properties.provisioningState}" \
      -o table 2>/dev/null | sed 's/^/    /' || echo "    <none or account not found>"
    echo ""

    echo "  Container Apps:"
    az containerapp list \
      --resource-group "$RG" \
      --query "[].{Name:name, FQDN:properties.configuration.ingress.fqdn, State:properties.provisioningState}" \
      -o table 2>/dev/null | sed 's/^/    /' || echo "    <none>"
    echo ""

  done <<< "$RGS"
fi

# ── Soft-deleted Cognitive Services accounts ──────────────────────────────────

echo "--- Soft-deleted Cognitive Services accounts ---"
DELETED=$(az cognitiveservices account list-deleted \
  --query "[?starts_with(name, 'ai-maf-')].{Name:name, Location:location, PurgeDate:scheduledPurgeDate}" \
  -o table 2>/dev/null || true)
if [[ -n "$DELETED" ]]; then
  echo "$DELETED" | sed 's/^/  /'
else
  echo "  <none>"
fi
echo ""

# ── Terraform state ───────────────────────────────────────────────────────────

echo "--- Terraform state (infra/) ---"
cd "$ROOT/infra"
TF_RESOURCES=$(terraform state list 2>/dev/null || true)
if [[ -n "$TF_RESOURCES" ]]; then
  echo "$TF_RESOURCES" | sed 's/^/  /'
else
  echo "  <empty>"
fi

if [[ -z "$RGS" && -n "$TF_RESOURCES" ]]; then
  echo ""
  echo "DRIFT DETECTED: Azure is clean but Terraform state is non-empty."
  echo "  Run script 06 to clear it, or from infra/ directly:"
  echo "    terraform state list | xargs -r terraform state rm"
fi

echo ""
echo "=== Inventory complete ==="
