terraform {
  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

resource "random_string" "suffix" {
  length  = 8
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "random_password" "mcp_api_key" {
  length  = 32
  special = false
}

locals {
  suffix = random_string.suffix.result
  tags   = { project = "multi-agent-foundry", managed_by = "terraform" }
}

# ── Resource group ────────────────────────────────────────────────────────────

resource "azapi_resource" "rg" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = "rg-maf-${local.suffix}"
  location  = var.region
  body      = { tags = local.tags }
}

# ── Foundry account (Cognitive Services, AIServices kind) ─────────────────────

resource "azapi_resource" "foundry_account" {
  type                      = "Microsoft.CognitiveServices/accounts@2025-04-01-preview"
  name                      = "ai-maf-${local.suffix}"
  parent_id                 = azapi_resource.rg.id
  location                  = var.region
  schema_validation_enabled = false

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "AIServices"
    sku  = { name = "S0" }
    properties = {
      customSubDomainName    = "ai-maf-${local.suffix}"
      disableLocalAuth       = false
      publicNetworkAccess    = "Enabled"
      allowProjectManagement = true
    }
    tags = local.tags
  }

  response_export_values = ["properties.apiKeys", "properties.endpoint"]
}

# ── Wait for managed identity propagation ────────────────────────────────────
# Azure provisions the identity's Entra service principal asynchronously;
# project creation fails if it starts before propagation completes.

resource "time_sleep" "wait_identity" {
  depends_on      = [azapi_resource.foundry_account]
  create_duration = "60s"
}

# ── Foundry project ───────────────────────────────────────────────────────────

resource "azapi_resource" "foundry_project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  name      = "proj-maf-${local.suffix}"
  parent_id = azapi_resource.foundry_account.id
  location  = var.region
  depends_on = [time_sleep.wait_identity]

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = { displayName = "multi-agent-foundry" }
    tags = local.tags
  }

  response_export_values = ["properties.endpoints"]
}

# ── GPT deployment ────────────────────────────────────────────────────────────

resource "azapi_resource" "gpt_deployment" {
  type      = "Microsoft.CognitiveServices/accounts/deployments@2024-10-01"
  name      = "${var.gpt_model}-${local.suffix}"
  parent_id = azapi_resource.foundry_account.id

  depends_on = [azapi_resource.foundry_project]

  body = {
    sku = { name = "Standard", capacity = 10 }
    properties = {
      model = {
        format  = "OpenAI"
        name    = var.gpt_model
        version = var.gpt_model_version
      }
    }
  }
}

# ── Claude deployment ─────────────────────────────────────────────────────────
# Created via CLI in 01_deploy_foundry.sh — Terraform's body serialization is
# incompatible with the modelProviderData JSON-string field that Anthropic
# deployments require.

# ── Role assignments ──────────────────────────────────────────────────────────
# Handled by az role assignment create in 01_deploy_foundry.sh (after apply).
# Terraform cannot do them: AZURE_* env vars cause the azapi provider to auth
# as the SP (Contributor), which lacks roleAssignments/write.

# ── Azure Container Registry ──────────────────────────────────────────────────

resource "azapi_resource" "acr" {
  type      = "Microsoft.ContainerRegistry/registries@2023-07-01"
  name      = "acrmaf${local.suffix}"
  parent_id = azapi_resource.rg.id
  location  = var.region

  body = {
    sku        = { name = "Basic" }
    properties = { adminUserEnabled = true }
    tags       = local.tags
  }

  response_export_values = ["properties.loginServer"]
}

# ── Container Apps environment ────────────────────────────────────────────────

resource "azapi_resource" "cae" {
  type      = "Microsoft.App/managedEnvironments@2024-03-01"
  name      = "cae-maf-${local.suffix}"
  parent_id = azapi_resource.rg.id
  location  = var.region

  body = {
    properties = { zoneRedundant = false }
    tags       = local.tags
  }
}

# ── Container App (MCP server) — created on second apply after image is built ─

resource "azapi_resource" "ca" {
  count     = var.image_tag != "" ? 1 : 0
  type      = "Microsoft.App/containerApps@2024-03-01"
  name      = "ca-mcp-${local.suffix}"
  parent_id = azapi_resource.rg.id
  location  = var.region

  body = {
    properties = {
      managedEnvironmentId = azapi_resource.cae.id
      configuration = {
        ingress = {
          external   = true
          targetPort = 8000
          transport  = "http"
        }
        registries = [{
          server            = azapi_resource.acr.output.properties.loginServer
          username          = azapi_resource.acr.name
          passwordSecretRef = "acr-password"
        }]
        secrets = [{
          name  = "acr-password"
          value = var.acr_password
        }, {
          name  = "mcp-api-key"
          value = random_password.mcp_api_key.result
        }]
      }
      template = {
        containers = [{
          name  = "mcp-server"
          image = "${azapi_resource.acr.output.properties.loginServer}/mcp-server:${var.image_tag}"
          resources = { cpu = 0.5, memory = "1Gi" }
          env = [{
            name      = "MCP_API_KEY"
            secretRef = "mcp-api-key"
          }]
        }]
        scale = { minReplicas = 1, maxReplicas = 1 }
      }
    }
    tags = local.tags
  }

  response_export_values = ["properties.configuration.ingress"]
}
