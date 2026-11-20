"""
Entry point for the multi-agent demo.
Usage:
  python demo.py tickets/ticket_A.pdf          # single ticket
  python demo.py tickets/ticket_A.pdf tickets/ticket_B.pdf
  python demo.py tickets/                       # all PDFs in directory
"""
import json
import logging
import os
import sys
from pathlib import Path

import yaml

from mcp_client import mcp_call, mcp_init_session

logging.basicConfig(level=logging.INFO, format="%(levelname)s  %(name)s  %(message)s")
# Suppress per-request header noise from Azure SDK; keep identity/coordinator/agent logs.
# logging.getLogger("azure.core.pipeline.policies.http_logging_policy").setLevel(logging.WARNING)
# logging.getLogger("azure.identity").setLevel(logging.WARNING)
logging.getLogger("azure.core.pipeline.policies.http_logging_policy").setLevel(logging.WARNING)
logging.getLogger("azure.identity").setLevel(logging.WARNING)
logger = logging.getLogger("demo")


def load_config(path: str = "config.local.yaml") -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def extract_ticket_id(pdf_path: Path) -> str:
    name = pdf_path.stem  # e.g. "ticket_A"
    mapping = {
        "ticket_A": "TKT-2024-001",
        "ticket_B": "TKT-2024-002",
        "ticket_C": "TKT-2024-003",
        "ticket_D": "TKT-2024-004",
        "ticket_E": "TKT-2024-005",
    }
    return mapping.get(name, name.upper())


def collect_pdfs(args: list[str]) -> list[Path]:
    paths = []
    for arg in args:
        p = Path(arg)
        if p.is_dir():
            paths.extend(sorted(p.glob("*.pdf")))
        elif p.is_file() and p.suffix == ".pdf":
            paths.append(p)
        else:
            logger.warning("Skipping %s (not a PDF file or directory)", arg)
    return paths


def header(title: str):
    width = 70
    print("\n" + "=" * width)
    print(f"  {title}")
    print("=" * width)


def step_mcp_handshake(mcp_url: str, mcp_api_key: str):
    header("STEP 1 — Raw MCP Handshake")

    print("\n→ Initializing MCP session...")
    session_id = mcp_init_session(mcp_url, mcp_api_key)
    print(f"   Session: {session_id}")

    print("\n→ Listing tools...")
    result = mcp_call(mcp_url, mcp_api_key, "tools/list", {}, session_id)
    tools = result.get("result", {}).get("tools", [])
    for t in tools:
        print(f"   • {t['name']}: {t.get('description', '')[:80]}")

    print("\n→ Calling get_ticket(TKT-2024-001)...")
    result = mcp_call(mcp_url, mcp_api_key, "tools/call", {
        "name": "get_ticket", "arguments": {"ticket_id": "TKT-2024-001"}
    }, session_id)
    content = result.get("result", {}).get("content", [])
    for block in content:
        if block.get("type") == "text":
            ticket = json.loads(block["text"])
            print(f"   ID: {ticket.get('id')}")
            print(f"   Subject: {ticket.get('subject')}")
            print(f"   From: {ticket.get('submitter')}")


def run_ticket(coordinator, ticket_id: str, label: str):
    header(f"Processing: {label} ({ticket_id})")
    initial_state = {
        "ticket_id": ticket_id,
        "ticket_text": "",
        "ticket": {},
        "triage": {},
        "response": {},
        "retry_count": 0,
        "error": None,
    }
    final_state = coordinator.invoke(initial_state)

    triage = final_state.get("triage", {})
    response = final_state.get("response", {})

    print(f"\nTriage:")
    print(f"  Category : {triage.get('category')}")
    print(f"  Priority : {triage.get('priority')}")
    print(f"  Needs KB : {triage.get('needs_kb')}")
    print(f"  KB topic : {triage.get('kb_topic')}")
    print(f"  Summary  : {triage.get('summary')}")

    print(f"\nResponse:")
    print(f"  KB used  : {response.get('kb_used')}")
    reply = response.get("reply", "")
    print(f"  Reply    : {reply[:300]}{'...' if len(reply) > 300 else ''}")

    return final_state


def main():
    cfg = load_config()
    mcp_url = os.environ.get("MCP_URL", cfg["mcp"]["url"])
    mcp_api_key = cfg["mcp"]["api_key"]

    # Step 1: raw handshake
    step_mcp_handshake(mcp_url, mcp_api_key)

    # Determine which tickets to run
    if len(sys.argv) > 1:
        pdf_paths = collect_pdfs(sys.argv[1:])
    else:
        tickets_dir = Path("tickets")
        if tickets_dir.exists():
            pdf_paths = sorted(tickets_dir.glob("*.pdf"))
        else:
            pdf_paths = []

    if not pdf_paths:
        print("\nNo PDF files found. Pass a file path or directory as argument.")
        print("Example: python demo.py tickets/ticket_A.pdf")
        sys.exit(1)

    # Build coordinator
    from graph.coordinator import build_coordinator
    coordinator = build_coordinator(
        project_endpoint=cfg["foundry"]["project_endpoint"],
        gpt_deployment=cfg["foundry"]["gpt_deployment"],
        foundry_endpoint=cfg["foundry"]["endpoint"],
        foundry_api_key=cfg["foundry"]["api_key"],
        claude_deployment=cfg["foundry"]["claude_deployment"],
        mcp_url=mcp_url,
        mcp_api_key=mcp_api_key,
    )

    # Print graph
    header("LangGraph — Coordinator Graph")
    try:
        print(coordinator.get_graph().draw_ascii())
    except Exception:
        pass

    # Run each ticket
    results = []
    scenario_labels = {
        "TKT-2024-001": "Ticket A — VPN issue (needs KB)",
        "TKT-2024-002": "Ticket B — Software install (no KB)",
        "TKT-2024-003": "Ticket C — Vague report (retry)",
        "TKT-2024-004": "Ticket D — CEO urgent (critical priority)",
        "TKT-2024-005": "Ticket E — Multi-issue compound ticket",
    }

    for pdf_path in pdf_paths:
        ticket_id = extract_ticket_id(pdf_path)
        label = scenario_labels.get(ticket_id, ticket_id)
        state = run_ticket(coordinator, ticket_id, label)
        results.append({
            "ticket_id": ticket_id,
            "label": label,
            "category": state["triage"].get("category", "—"),
            "priority": state["triage"].get("priority", "—"),
            "needs_kb": state["triage"].get("needs_kb", "—"),
            "kb_used": state["response"].get("kb_used") or "—",
            "retried": state["retry_count"] > 0,
        })

    # Summary table
    header("Summary")
    col = "{:<16} {:<12} {:<10} {:<8} {:<22} {}"
    print(col.format("Ticket ID", "Category", "Priority", "KB?", "KB Article", "Retried"))
    print("-" * 85)
    for r in results:
        print(col.format(
            r["ticket_id"],
            r["category"],
            r["priority"],
            str(r["needs_kb"]),
            str(r["kb_used"])[:22],
            "YES" if r["retried"] else "no",
        ))


if __name__ == "__main__":
    main()
