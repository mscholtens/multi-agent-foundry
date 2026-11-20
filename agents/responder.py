"""
Responder agent: Claude on Foundry Anthropic endpoint.
Manages the tool-use loop with Claude; delegates all MCP calls to a caller
function provided by the coordinator — the agent itself makes no HTTP calls.
"""
import json
import logging
from collections.abc import Callable

import anthropic

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are a helpful IT helpdesk responder. Your job is to write a clear,
professional response to a support ticket. You have access to a knowledge base tool — use it
when the ticket involves a known technical issue (VPN, password, printer, email, software).

Always respond in JSON with this exact structure:
{"reply": "<your response to the user>", "kb_used": "<article title or null>"}"""


class ResponderAgent:
    def __init__(self, endpoint: str, api_key: str, deployment: str, tool_definitions: list[dict]):
        self.client = anthropic.Anthropic(
            base_url=endpoint.rstrip('/'),
            api_key=api_key,
            default_headers={"x-ms-model-mesh-model-name": deployment},
        )
        self.deployment = deployment
        self.tool_definitions = tool_definitions

    def run(self, ticket: dict, triage: dict, mcp_caller: Callable[[str, dict], dict]) -> dict:
        user_message = (
            f"Ticket ID: {ticket['id']}\n"
            f"From: {ticket['submitter']}\n"
            f"Subject: {ticket['subject']}\n\n"
            f"{ticket['body']}\n\n"
            f"[Triage classification: category={triage.get('category')}, "
            f"priority={triage.get('priority')}, "
            f"kb_topic={triage.get('kb_topic')}]"
        )

        messages = [{"role": "user", "content": user_message}]

        while True:
            logger.info("Calling Claude (%s), %d messages", self.deployment, len(messages))
            response = self.client.messages.create(
                model=self.deployment,
                max_tokens=2048,
                system=SYSTEM_PROMPT,
                tools=self.tool_definitions,
                messages=messages,
            )
            logger.debug("Stop reason: %s", response.stop_reason)

            messages.append({"role": "assistant", "content": response.content})

            if response.stop_reason == "tool_use":
                tool_results = []
                for block in response.content:
                    if block.type == "tool_use":
                        logger.info("Tool call: %s(%s)", block.name, block.input)
                        result = mcp_caller(block.name, block.input)
                        logger.info("Tool result: %s", result)
                        tool_results.append({
                            "type": "tool_result",
                            "tool_use_id": block.id,
                            "content": json.dumps(result),
                        })
                messages.append({"role": "user", "content": tool_results})
                continue

            # stop_reason == "end_turn"
            for block in response.content:
                if hasattr(block, "text"):
                    text = block.text.strip()
                    # strip markdown code fences if present
                    if text.startswith("```"):
                        lines = text.splitlines()
                        text = "\n".join(lines[1:-1] if lines[-1] == "```" else lines[1:])
                    try:
                        return json.loads(text)
                    except json.JSONDecodeError:
                        return {"reply": text, "kb_used": None}

            logger.warning("No text block in response (stop_reason=%s, content=%s)",
                           response.stop_reason, response.content)
            return {"reply": "No response generated.", "kb_used": None}
