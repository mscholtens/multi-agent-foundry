# multi-agent-foundry

A lab demonstrating a simple multi-agent system using MCP, LangGraph, Microsoft Foundry (Azure AI Services), and Terraform. A local LangGraph coordinator routes IT helpdesk support tickets through two AI agents — one GPT-based for triage, one Claude-based for response — with tools served over a FastMCP server hosted on Azure Container Apps.

## Repository structure

```
infra/          Terraform: Foundry account, project, deployments, ACR, Container Apps
mcp_server/     FastMCP server + data files
agents/         Triage and Responder agent modules
graph/          LangGraph coordinator
scripts/        Numbered shell scripts (01–07)
tickets/        Sample PDF tickets + DEMO.md
demo.py         Entry point for the coordinator
config.example.yaml
```

## Prerequisites

- Python 3.11+
- Terraform >= 1.6
- Azure CLI (`az`) — logged in via `az login`
- An Azure subscription with access to Azure AI Services (Foundry) and Container Apps

Install Python dependencies:
```bash
pip install -r requirements.txt
```

Make scripts executable (required before first run):
```bash
chmod +x scripts/*.sh
```

## Configuration

Copy `config.example.yaml` to `config.local.yaml` and fill in your values:
```bash
cp config.example.yaml config.local.yaml
```

**Where to get each credential:**

| Field | Where to find it |
|-------|-----------------|
| `azure.subscription_id` | `az account show --query id -o tsv` |
| `azure.tenant_id` | `az account show --query tenantId -o tsv` |
| `azure.region` | Choose a region where both GPT and Claude Global Standard are available (e.g. `swedencentral` or `eastus2`). Verify at [Azure AI model catalog](https://ai.azure.com). |
| `foundry.*` | Populated automatically by `scripts/01_deploy_foundry.sh` from `terraform output` |
| `mcp.*` | Populated automatically by `scripts/02_deploy_mcp_server.sh` from `terraform output` |

`config.local.yaml` is gitignored. Never commit it.

## Running the lab

```bash
# 1. Provision Foundry (Cognitive Services account, project, model deployments, role)
./scripts/01_deploy_foundry.sh

# 2. Build and deploy the MCP server to Azure Container Apps
./scripts/02_deploy_mcp_server.sh

# 3. Verify both are healthy
./scripts/03_status.sh

# 4. Run the demo (interactive — choose a file or * for all tickets)
./scripts/04_run_demo.sh

# 5–6. Tear down when done
./scripts/05_teardown_mcp_server.sh
./scripts/06_teardown_foundry.sh
```

### Dev mode (no Azure required for MCP server)

```bash
python mcp_server/server.py &
MCP_URL=http://localhost:8000/mcp python demo.py tickets/ticket_A.pdf
```

### Azure inventory

```bash
./scripts/07_azure_inventory.sh
```

## Demo scenarios

See `tickets/DEMO.md` for a description of each ticket, expected triage output, and what to observe.

## Notes

- All Azure resource names include a random suffix — no collisions between runs.
- Soft-deleted Cognitive Services accounts are purged automatically during teardown (`06_teardown_foundry.sh`).
- If the Claude deployment can't be created via Terraform (marketplace acceptance step), `01_deploy_foundry.sh` falls back to `az cognitiveservices account deployment create`.
