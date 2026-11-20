# multi-agent-foundry

A lab demonstrating a multi-agent setup using MCP, LangGraph, Microsoft Foundry, and Terraform.

Read `ARCHITECTURE.md` before making structural changes. It is the authoritative design reference.

## What this project is

A LangGraph coordinator (local) routes IT helpdesk support tickets (PDF) through two sub-agents on Microsoft Foundry:
- **Triage**: Foundry Agent Service (GPT) — returns JSON classification.
- **Responder**: Claude via Foundry's Anthropic endpoint — tool-use loop calling `lookup_kb` over MCP.

Tools are served by a FastMCP server on Azure Container Apps.

## Principles

- Keep it small. This is a lab, not a product. Prefer fewer files and plain code over abstractions.
- No CI/CD, no RAG, no monitoring/evals, no production auth. Those are out of scope.
- Python 3.11+, Terraform with the `azapi` provider (plus `random`).
- Everything in Azure must be destroyable by `scripts/06_teardown_foundry.sh`. Random suffix on all resource names.

## Secrets

- Credentials live in `config.local.yaml` (gitignored), populated from `terraform output -json`.
- Never commit `config.local.yaml`, `*.tfstate*`, `.terraform/`, or `.env`.
- Foundry Agent Service uses Entra ID (`az login` + `DefaultAzureCredential`); Claude calls use the API key.

## Commands

- Full flow: `scripts/01` → `02` → `03` → `04` → `05` → `06`
- Dev mode: `MCP_URL=http://localhost:8000/mcp python demo.py tickets/ticket_A.pdf` with `python mcp_server/server.py` running locally

## Things to verify against current docs

- Whether the Claude deployment can be created via Terraform/azapi or needs `az cognitiveservices account deployment create`.
- Current `azure-ai-projects` SDK API for creating agents and attaching an MCP tool.
- Whether Foundry's MCP tool can send a custom `x-api-key` header (fallback: key in query string, lab only).
- Current API versions for `Microsoft.CognitiveServices/accounts` and `/projects`.
- Region availability for both GPT model and Claude Global Standard.
