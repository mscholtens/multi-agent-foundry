#!/usr/bin/env bash
# Shared auth helper. Source this after setting CONFIG and the SUBSCRIPTION_ID /
# TENANT_ID / REGION variables. Sets PRINCIPAL_ID and, when using a service
# principal, exports AZURE_* env vars so DefaultAzureCredential works too.

read_yaml() { python3 -c "import yaml,sys; c=yaml.safe_load(open('$CONFIG')); print(c$1)" 2>/dev/null || echo ""; }

SUBSCRIPTION_ID=$(read_yaml "['azure']['subscription_id']")
TENANT_ID=$(read_yaml "['azure']['tenant_id']")
REGION=$(read_yaml "['azure']['region']")

if [[ -z "$SUBSCRIPTION_ID" || "$SUBSCRIPTION_ID" == "PLACEHOLDER" ]]; then
  echo "ERROR: Set azure.subscription_id in config.local.yaml"
  exit 1
fi

CLIENT_ID=$(read_yaml "['azure']['client_id']")
CLIENT_SECRET=$(read_yaml "['azure']['client_secret']")

# Always require an interactive az login — Terraform runs as this user so it
# has Owner and can write role assignments regardless of SP credential config.
az account show --query id -o tsv >/dev/null 2>&1 \
  || { echo "ERROR: Not logged in. Run: az login"; exit 1; }

# Activate the subscription from config so az CLI + Terraform target the right one.
az account set --subscription "$SUBSCRIPTION_ID" --output none

if [[ -n "$CLIENT_ID" && "$CLIENT_ID" != "PLACEHOLDER" \
   && -n "$CLIENT_SECRET" && "$CLIENT_SECRET" != "PLACEHOLDER" ]]; then
  # Verify the active az CLI session is a USER account, not the SP.
  # If it's the SP (Contributor), role assignment commands will silently fail.
  _SESSION_TYPE=$(az account show --query user.type -o tsv 2>/dev/null)
  if [[ "$_SESSION_TYPE" == "servicePrincipal" ]]; then
    echo ""
    echo "ERROR: az CLI is currently logged in as SP ($CLIENT_ID)."
    echo "  Role assignments require a user account with Owner. Fix:"
    echo "    az logout --username $CLIENT_ID"
    echo "    az login"
    exit 1
  fi

  # Look up the SP's object ID using the user's session (read-only Graph call).
  # SP creds are exported for DefaultAzureCredential in the Python demo — Terraform
  # stays on the user's session (Owner) so it can write role assignments.
  PRINCIPAL_ID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv 2>/dev/null) \
    || { echo "ERROR: Cannot look up SP '$CLIENT_ID'. Check azure.client_id in config.local.yaml."; exit 1; }
  export AZURE_CLIENT_ID="$CLIENT_ID"
  export AZURE_CLIENT_SECRET="$CLIENT_SECRET"
  export AZURE_TENANT_ID="$TENANT_ID"
  echo "SP configured: $CLIENT_ID (object id: $PRINCIPAL_ID)"
  echo "az CLI session: $(az account show --query user.name -o tsv)"
else
  PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv)
fi
