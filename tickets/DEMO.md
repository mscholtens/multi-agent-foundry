# Demo Scenarios

Five IT helpdesk tickets are included. Each tests a different routing path or edge case in the coordinator.

---

## Ticket A — VPN not connecting after password change (`ticket_A.pdf`)

**Ticket ID:** TKT-2024-001  
**Submitter:** Sarah Chen  
**Expected triage output:**
```json
{
  "category": "access",
  "priority": "medium",
  "needs_kb": true,
  "kb_topic": "VPN GlobalProtect password authentication",
  "summary": "User cannot connect to VPN after AD password change; authentication fails."
}
```
**Expected responder behaviour:** Calls `lookup_kb("VPN GlobalProtect password authentication")`, retrieves KB-001, incorporates step-by-step reconnection instructions into the reply.  
**What to observe:** The routing takes the `respond_with_kb` path. Claude's tool-use loop is visible in the logs — one `tool_use` block followed by a `tool_result`. The final reply references specific steps from the KB article.

---

## Ticket B — Software install request (`ticket_B.pdf`)

**Ticket ID:** TKT-2024-002  
**Submitter:** James Miller  
**Expected triage output:**
```json
{
  "category": "software",
  "priority": "low",
  "needs_kb": false,
  "kb_topic": null,
  "summary": "User requests Slack installation on managed laptop before Monday sprint kick-off."
}
```
**Expected responder behaviour:** No KB lookup. Claude replies directly based on the ticket content and its training, directing the user to the Self-Service portal or IT team.  
**What to observe:** The coordinator takes the `respond_plain` path (no MCP tool call from Claude). `kb_used` in the summary table shows `—`.

---

## Ticket C — Vague report, missing details (`ticket_C.pdf`)

**Ticket ID:** TKT-2024-003  
**Submitter:** Bob (no last name, no asset tag)  
**Expected triage output (first attempt — may be malformed or missing fields):**  
The ticket is intentionally vague. The triage agent may return an incomplete JSON (missing `needs_kb` or `kb_topic`) or set `category: "other"` with `needs_kb: false`.  
**Expected responder behaviour:** The `validate` node detects a schema issue on the first attempt and fires one retry. On retry the coordinator asks triage again with an explicit schema reminder.  
**What to observe:** `retry_count` is 1 in the final state. The `Retried: YES` column in the summary table. The validation path in the LangGraph graph is exercised.

---

## Ticket D — Urgent: CEO laptop won't boot (`ticket_D.pdf`)

**Ticket ID:** TKT-2024-004  
**Submitter:** Emma Watts (PA to CEO)  
**Expected triage output:**
```json
{
  "category": "hardware",
  "priority": "critical",
  "needs_kb": true,
  "kb_topic": "laptop boot failure blue screen loaner",
  "summary": "CEO laptop fails to boot (BSOD) with board presentation in 90 minutes; loaner device may be needed."
}
```
**Expected responder behaviour:** Calls `lookup_kb` for hardware/BSOD, retrieves KB-003, includes the IT hotline number and loaner device location in the reply.  
**What to observe:** `priority: critical` propagates correctly. Claude's reply should acknowledge urgency and provide the fastest resolution path (hotline + loaner).

---

## Ticket E — Multi-issue compound ticket (`ticket_E.pdf`)

**Ticket ID:** TKT-2024-005  
**Submitter:** Lisa Rodriguez  
**Expected triage output:**
```json
{
  "category": "network",
  "priority": "medium",
  "needs_kb": true,
  "kb_topic": "printer offline network slow Outlook sync",
  "summary": "Three concurrent issues: slow PC, floor printer offline (affects multiple users), Outlook inbox sync stuck."
}
```
**Expected responder behaviour:** Calls `lookup_kb` for the highest-impact issue (printer offline affecting multiple users). The reply should address all three issues but focus triage on the shared printer as a potential network-side problem.  
**What to observe:** How the triage agent handles a ticket with multiple independent issues — it should pick the most significant category and note the others in `summary`. Claude's reply should address all three issues in a structured way.
