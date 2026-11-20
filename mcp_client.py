"""Shared MCP client helpers. FastMCP 2.x requires an initialize handshake and SSE streaming."""
import json
import httpx

_HEADERS_BASE = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}


def mcp_init_session(url: str, api_key: str) -> str:
    payload = {
        "jsonrpc": "2.0", "id": 0,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "multi-agent-foundry", "version": "0.1"},
        },
    }
    resp = httpx.post(
        url.rstrip("/"), json=payload,
        headers={**_HEADERS_BASE, "x-api-key": api_key},
        timeout=15,
    )
    resp.raise_for_status()
    session_id = resp.headers.get("mcp-session-id", "")
    if not session_id:
        raise RuntimeError(f"Server did not return Mcp-Session-Id; headers: {dict(resp.headers)}")
    return session_id


def mcp_call(url: str, api_key: str, method: str, params: dict, session_id: str = "") -> dict:
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    headers = {**_HEADERS_BASE, "x-api-key": api_key}
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    with httpx.stream("POST", url.rstrip("/"), json=payload, headers=headers, timeout=30) as resp:
        content_type = resp.headers.get("content-type", "")
        if not resp.is_success:
            body = resp.read()
            print(f"  HTTP {resp.status_code} — body: {body.decode()[:800]}")
            resp.raise_for_status()
        if "text/event-stream" in content_type:
            for line in resp.iter_lines():
                if line.startswith("data:"):
                    data = line[5:].strip()
                    if data:
                        return json.loads(data)
            raise RuntimeError(f"SSE stream for {method!r} contained no data")
        body = resp.read()
        return json.loads(body)
