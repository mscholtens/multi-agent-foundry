# Architecture Reference

## System topology

```
[PDF files on disk]
      │ path(s)
      ▼
[demo.py]  ←─ config.local.yaml (foundry.*, mcp.*)
      │
      ▼
[LangGraph StateGraph — graph/coordinator.py]
      │  ← MCP client (httpx, raw JSON-RPC)
      │      startup: tools/list → discovers tool schemas, passes to Responder
      │      tools called directly: get_ticket, save_result
      │
      ├─────────────────────────────────────────────────┐
      │ azure-ai-projects SDK                           │ AnthropicFoundry client
      │ DefaultAzureCredential                          │ API key auth
      ▼                                                 ▼
[Triage agent — Foundry Agent Service]      [Responder agent — Claude Haiku]
  GPT deployment                              claude-haiku-* deployment
  Foundry project scope                       Foundry Anthropic endpoint
  Returns JSON (no tool use)                  tool-use loop — returns tool_use blocks
      │                                           │ ↑ coordinator intercepts,
      │                                           │   calls lookup_kb via MCP,
      │                                           │   feeds tool_result back
      │                              [MCP Server — Azure Container App]
      │                                FastMCP, streamable HTTP
      │                                port 8000, path /mcp
      │                                auth: x-api-key header
      │                                      (query-string fallback)
      │                                tools: get_ticket, lookup_kb, save_result
      │                                data: static JSON files in container
      │
      └───── get_ticket · lookup_kb · save_result ──→ [MCP Server]
```

## Component contracts

### MCP server tools

| Tool | Signature | Behaviour |
|------|-----------|-----------|
| `get_ticket` | `(ticket_id: str) → dict` | Returns ticket JSON by ID; 404-style error if not found |
| `lookup_kb` | `(topic: str) → dict` | Keyword match against `kb.json`; returns best article or empty dict |
| `save_result` | `(ticket_id: str, payload: dict) → dict` | Stores result in process memory; returns `{status: "saved", ticket_id}` |

Authentication: every request must carry `x-api-key: <MCP_API_KEY>` header. Lab fallback: `?api_key=<MCP_API_KEY>` query param.

### Triage agent output schema

```json
{
  "category": "access" | "hardware" | "software" | "network" | "other",
  "priority": "low" | "medium" | "high" | "critical",
  "needs_kb": true | false,
  "kb_topic": "<string>" | null,
  "summary": "<one-sentence summary>"
}
```

Validation: coordinator checks schema; on failure, retries once with explicit schema reminder in the prompt.

### Responder agent output schema

```json
{
  "reply": "<response text to the user>",
  "kb_used": "<article title>" | null
}
```

## LangGraph state and graph

```python
class TicketState(TypedDict):
    ticket_id: str
    ticket_text: str
    triage: dict        # populated by triage node
    response: dict      # populated by responder node
    retry_count: int
    error: str | None
```

Nodes: `fetch_ticket` → `triage` → (conditional) → `respond_with_kb` | `respond_plain` → `validate` → `save`

Conditional edge on `triage["needs_kb"]`: True → `respond_with_kb`, False → `respond_plain`.

Validate node: checks response JSON schema; if invalid and `retry_count < 1`, increments counter and loops back to the appropriate responder node.

## Infrastructure

All resources share a `random_string` suffix (8 chars, lowercase alpha) to avoid name collisions across runs.

### Terraform resource graph

```
azapi_resource.rg
  └─ azapi_resource.foundry_account  (Microsoft.CognitiveServices/accounts, kind=AIServices, sku=S0)
        ├─ azapi_resource.foundry_project  (Microsoft.CognitiveServices/accounts/projects)
        │     └─ azurerm_role_assignment.foundry_user  ("Cognitive Services User" on project)
        ├─ azapi_resource.gpt_deployment   (Microsoft.CognitiveServices/accounts/deployments)
        └─ azapi_resource.claude_deployment (same, model=claude-haiku-*, Global Standard)
azapi_resource.acr  (Microsoft.ContainerRegistry/registries, Basic)
azapi_resource.cae  (Microsoft.App/managedEnvironments)
azapi_resource.ca   (Microsoft.App/containerApps, count = image_tag != "" ? 1 : 0)
random_password.mcp_api_key
```

Two-phase apply: first apply creates everything except `ca`; `az acr build` pushes the image; second apply with `-var image_tag=<digest>` creates the Container App.

### Sensitive outputs

`foundry_api_key`, `mcp_api_key` — marked sensitive in Terraform. Written to `config.local.yaml` by scripts.

## MCP server container

Base image: `python:3.11-slim`. Working dir `/app`. Copies `server.py`, `requirements.txt`, `data/`. Runs `uvicorn` or `fastmcp` serve on port 8000. `MCP_API_KEY` injected as Container App env var from `random_password.mcp_api_key`.

## Auth model

| Component | Auth method |
|-----------|-------------|
| Triage agent (Foundry Agent Service) | Entra ID — `DefaultAzureCredential` (requires `az login`) |
| Responder agent (Claude on Foundry) | API key — `foundry.api_key` from config |
| MCP server | Static key — `mcp.api_key` from config, sent as `x-api-key` header |
| Terraform | Azure CLI credential via `azurerm`/`azapi` provider defaults |

## Known constraints and fallbacks

- **Claude deployment via Terraform**: `azapi` may fail if the marketplace agreement hasn't been accepted. `01_deploy_foundry.sh` catches this and retries with `az cognitiveservices account deployment create`.
- **Soft-delete on Cognitive Services accounts**: Azure soft-deletes the account for 48h after `destroy`. `06_teardown_foundry.sh` runs `az cognitiveservices account purge` to allow immediate name reuse.
- **Foundry MCP tool headers**: Whether Foundry's hosted agent MCP client forwards custom headers is unverified. Fallback: append `?api_key=<key>` to `mcp.url` for the triage agent config only.
- **Region**: Both GPT (Standard/GlobalStandard) and Claude Haiku (Global Standard) must be available. Verified regions at time of writing: `swedencentral`, `eastus2`. Check the Azure model catalog before first apply.

## Data files

### mcp_server/data/tickets.json

```json
[
  {"id": "TKT-2024-001", "submitter": "...", "subject": "...", "body": "..."},
  ...
]
```

Five tickets corresponding to `tickets/ticket_A.pdf` through `ticket_E.pdf`. IDs match filenames (extracted from PDF metadata or first line).

### mcp_server/data/kb.json

```json
[
  {"id": "KB-001", "title": "...", "keywords": ["vpn", "globalprotect", "..."], "content": "..."},
  ...
]
```

Four to six articles covering: VPN/GlobalProtect, password reset, software installation policy, hardware replacement, network connectivity troubleshooting.

## Coordinator flow (demo.py)

1. **MCP handshake** — raw: list tools, call `get_ticket("TKT-2024-001")`, print exchange.
2. **Ticket A** — VPN issue, needs KB. Full path: triage → respond_with_kb.
3. **Ticket B** — Software install request, no KB. Path: triage → respond_plain.
4. **Ticket C** — Vague report. Triage returns ambiguous JSON → validate fails → retry.
5. **Ticket D** — Critical priority (CEO laptop). Tests priority field propagation.
6. **Ticket E** — Multi-issue ticket. Tests triage handling of compound requests.
7. **Summary table** — ticket ID, category, priority, kb_used, response length.
