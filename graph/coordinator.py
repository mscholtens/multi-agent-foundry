"""
LangGraph coordinator: routes tickets through triage → responder.
Acts as MCP client: discovers tool schemas via tools/list at startup,
calls get_ticket and save_result directly, and passes discovered schemas to ResponderAgent.
"""
import json
import logging
from typing import Literal, TypedDict

from langgraph.graph import END, StateGraph

from agents.triage import TriageAgent
from agents.responder import ResponderAgent
from mcp_client import mcp_init_session, mcp_call as _mcp_call_raw

logger = logging.getLogger(__name__)


class TicketState(TypedDict):
    ticket_id: str
    ticket_text: str
    ticket: dict
    triage: dict
    response: dict
    retry_count: int
    error: str | None


TRIAGE_SCHEMA = {"category", "priority", "needs_kb", "summary"}
RESPONSE_SCHEMA = {"reply", "kb_used"}


def build_coordinator(
    project_endpoint: str,
    gpt_deployment: str,
    foundry_endpoint: str,
    foundry_api_key: str,
    claude_deployment: str,
    mcp_url: str,
    mcp_api_key: str,
):
    triage_agent = TriageAgent(project_endpoint, gpt_deployment)

    # One session per coordinator instance; all MCP calls share it.
    mcp_session_id = mcp_init_session(mcp_url, mcp_api_key)
    logger.info("MCP session: %s", mcp_session_id)

    def _mcp_call(method: str, params: dict) -> dict:
        result = _mcp_call_raw(mcp_url, mcp_api_key, method, params, mcp_session_id)
        if "error" in result:
            raise RuntimeError(f"MCP error: {result['error']}")
        content = result.get("result", {}).get("content", [])
        for block in content:
            if block.get("type") == "text":
                try:
                    return json.loads(block["text"])
                except json.JSONDecodeError:
                    return {"text": block["text"]}
        return {}

    def _discover_tools() -> list[dict]:
        result = _mcp_call_raw(mcp_url, mcp_api_key, "tools/list", {}, mcp_session_id)
        if "error" in result:
            raise RuntimeError(f"MCP tools/list error: {result['error']}")
        tools = result.get("result", {}).get("tools", [])
        # Only pass fields the Anthropic API accepts; drop MCP extras like _meta, annotations.
        return [
            {
                "name": t["name"],
                "description": t.get("description", ""),
                "input_schema": t["inputSchema"],
            }
            for t in tools
        ]

    mcp_tools = _discover_tools()
    logger.info("Discovered %d MCP tools: %s", len(mcp_tools), [t["name"] for t in mcp_tools])

    # Derive the account-level endpoint from the project endpoint.
    # project: https://ai-maf-xxx.services.ai.azure.com/api/projects/proj-maf-xxx
    # account: https://ai-maf-xxx.services.ai.azure.com
    _claude_account = (
        project_endpoint.split("/api/projects/")[0]
        if "/api/projects/" in project_endpoint
        else foundry_endpoint.rstrip("/")
    )
    # Foundry Anthropic API path: /anthropic
    # Anthropic SDK appends /v1/messages → full URL:
    # https://ai-maf-xxx.services.ai.azure.com/anthropic/v1/messages
    _claude_endpoint = f"{_claude_account}/anthropic"

    responder_agent = ResponderAgent(
        _claude_endpoint, foundry_api_key, claude_deployment,
        tool_definitions=mcp_tools,
    )

    def fetch_ticket(state: TicketState) -> TicketState:
        logger.info("[fetch_ticket] %s", state["ticket_id"])
        ticket = _mcp_call("tools/call", {"name": "get_ticket", "arguments": {"ticket_id": state["ticket_id"]}})
        return {**state, "ticket": ticket}

    def triage(state: TicketState) -> TicketState:
        logger.info("[triage] %s", state["ticket_id"])
        result = triage_agent.run(state["ticket"])
        logger.info("[triage] result: %s", result)
        return {**state, "triage": result}

    def _mcp_tool_caller(name: str, args: dict) -> dict:
        return _mcp_call("tools/call", {"name": name, "arguments": args})

    def respond_with_kb(state: TicketState) -> TicketState:
        logger.info("[respond_with_kb] %s", state["ticket_id"])
        result = responder_agent.run(state["ticket"], state["triage"], mcp_caller=_mcp_tool_caller)
        logger.info("[respond_with_kb] result: %s", result)
        return {**state, "response": result}

    def respond_plain(state: TicketState) -> TicketState:
        logger.info("[respond_plain] %s", state["ticket_id"])
        result = responder_agent.run(state["ticket"], state["triage"], mcp_caller=_mcp_tool_caller)
        logger.info("[respond_plain] result: %s", result)
        return {**state, "response": result}

    def validate(state: TicketState) -> TicketState:
        triage_ok = TRIAGE_SCHEMA.issubset(state.get("triage", {}).keys())
        response_ok = RESPONSE_SCHEMA.issubset(state.get("response", {}).keys())
        if not triage_ok or not response_ok:
            logger.warning("[validate] schema mismatch — triage_ok=%s response_ok=%s", triage_ok, response_ok)
            return {**state, "error": "schema_mismatch"}
        return {**state, "error": None}

    def save(state: TicketState) -> TicketState:
        logger.info("[save] %s", state["ticket_id"])
        _mcp_call("tools/call", {
            "name": "save_result",
            "arguments": {
                "ticket_id": state["ticket_id"],
                "payload": {"triage": state["triage"], "response": state["response"]},
            }
        })
        return state

    def route_after_triage(state: TicketState) -> Literal["respond_with_kb", "respond_plain"]:
        return "respond_with_kb" if state["triage"].get("needs_kb") else "respond_plain"

    def route_after_validate(state: TicketState) -> Literal["retry_triage", "save"]:
        if state.get("error") and state.get("retry_count", 0) < 1:
            return "retry_triage"
        return "save"

    def retry_triage(state: TicketState) -> TicketState:
        logger.info("[retry_triage] %s (attempt %d)", state["ticket_id"], state["retry_count"] + 1)
        result = triage_agent.run(state["ticket"])
        return {**state, "triage": result, "retry_count": state["retry_count"] + 1, "error": None}

    graph = StateGraph(TicketState)
    graph.add_node("fetch_ticket", fetch_ticket)
    graph.add_node("triage", triage)
    graph.add_node("respond_with_kb", respond_with_kb)
    graph.add_node("respond_plain", respond_plain)
    graph.add_node("validate", validate)
    graph.add_node("retry_triage", retry_triage)
    graph.add_node("save", save)

    graph.set_entry_point("fetch_ticket")
    graph.add_edge("fetch_ticket", "triage")
    graph.add_conditional_edges("triage", route_after_triage)
    graph.add_edge("respond_with_kb", "validate")
    graph.add_edge("respond_plain", "validate")
    graph.add_conditional_edges("validate", route_after_validate)
    graph.add_edge("retry_triage", "respond_plain")
    graph.add_edge("save", END)

    return graph.compile()
