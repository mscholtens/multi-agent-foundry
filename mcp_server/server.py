import json
import os
from pathlib import Path

from fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

DATA_DIR = Path(__file__).parent / "data"
MCP_API_KEY = os.environ.get("MCP_API_KEY", "dev-key")

with open(DATA_DIR / "tickets.json") as f:
    _tickets = {t["id"]: t for t in json.load(f)}

with open(DATA_DIR / "kb.json") as f:
    _kb_articles = json.load(f)

_results: dict = {}

mcp = FastMCP("helpdesk-mcp")


def _check_auth(request: Request) -> bool:
    key = request.headers.get("x-api-key") or request.query_params.get("api_key")
    return key == MCP_API_KEY


@mcp.tool(description="Retrieve a support ticket by its ID. Returns the full ticket including submitter, subject, and body.")
def get_ticket(ticket_id: str) -> dict:
    ticket = _tickets.get(ticket_id)
    if not ticket:
        return {"error": f"Ticket {ticket_id!r} not found"}
    return ticket


@mcp.tool(description="Look up a knowledge base article by topic keyword. Returns the best matching article including its content and resolution steps. Use this when the ticket involves a known technical issue such as VPN, password, printer, email, or software installation.")
def lookup_kb(topic: str) -> dict:
    topic_lower = topic.lower()
    scored = []
    for article in _kb_articles:
        score = sum(1 for kw in article["keywords"] if kw in topic_lower)
        if score:
            scored.append((score, article))
    if not scored:
        return {"found": False, "message": "No matching article found"}
    _, best = max(scored, key=lambda x: x[0])
    return {"found": True, "article": best}


@mcp.tool(description="Save the final resolution result for a ticket. Call this after generating the response to persist the outcome.")
def save_result(ticket_id: str, payload: dict) -> dict:
    _results[ticket_id] = payload
    return {"status": "saved", "ticket_id": ticket_id}


class _AuthMiddleware:
    """Pure ASGI middleware — does not touch the request body stream."""
    def __init__(self, app):
        self._app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            headers = {k.lower(): v for k, v in scope.get("headers", [])}
            key = headers.get(b"x-api-key", b"").decode()
            if not key:
                qs = scope.get("query_string", b"").decode()
                for part in qs.split("&"):
                    if part.startswith("api_key="):
                        key = part[8:]
            if key != MCP_API_KEY:
                body = b'{"error":"Unauthorized"}'
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"application/json"),
                                        (b"content-length", str(len(body)).encode())]})
                await send({"type": "http.response.body", "body": body})
                return
        await self._app(scope, receive, send)


if __name__ == "__main__":
    import uvicorn
    app = _AuthMiddleware(mcp.http_app(path="/mcp"))
    uvicorn.run(app, host="0.0.0.0", port=8000)
