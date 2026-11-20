"""
Triage agent: GPT on Microsoft Foundry Agent Service.
Creates an ephemeral agent, runs it on the ticket, deletes it.
"""
import json
import logging

from azure.ai.agents import AgentsClient
from azure.ai.agents.models import MessageRole
from azure.identity import DefaultAzureCredential

logger = logging.getLogger(__name__)

INSTRUCTIONS = """You are an IT helpdesk triage agent. Classify the support ticket and return ONLY valid JSON — no markdown, no explanation — with this exact structure:

{
  "category": "access" | "hardware" | "software" | "network" | "other",
  "priority": "low" | "medium" | "high" | "critical",
  "needs_kb": true | false,
  "kb_topic": "<search keywords for KB lookup>" | null,
  "summary": "<one sentence describing the issue>"
}

Rules:
- Set needs_kb=true when the issue involves a known technical procedure (VPN, password, printer, email sync, software install).
- Set kb_topic to 2-4 keywords that best describe the issue when needs_kb=true, otherwise null.
- For compound tickets with multiple issues, classify the highest-priority issue and note others in summary.
- For vague or incomplete tickets, set category="other", needs_kb=false, and note missing information in summary."""


class TriageAgent:
    def __init__(self, project_endpoint: str, gpt_deployment: str):
        self.client = AgentsClient(
            endpoint=project_endpoint,
            credential=DefaultAzureCredential(),
        )
        self.deployment = gpt_deployment

    def run(self, ticket: dict) -> dict:
        agent = self.client.create_agent(
            model=self.deployment,
            name=f"triage-{ticket['id']}",
            instructions=INSTRUCTIONS,
        )
        logger.info("Created triage agent %s", agent.id)
        try:
            thread = self.client.threads.create()
            self.client.messages.create(
                thread_id=thread.id,
                role=MessageRole.USER,
                content=(
                    f"Ticket ID: {ticket['id']}\n"
                    f"From: {ticket['submitter']}\n"
                    f"Subject: {ticket['subject']}\n\n"
                    f"{ticket['body']}"
                ),
            )
            run = self.client.runs.create_and_process(
                thread_id=thread.id,
                agent_id=agent.id,
            )
            logger.info("Run status: %s", run.status)

            messages = self.client.messages.list(thread_id=thread.id)
            for msg in messages:
                if msg.role == MessageRole.AGENT:
                    for content_block in msg.content:
                        if hasattr(content_block, "text"):
                            text = content_block.text.value.strip()
                            if text.startswith("```"):
                                lines = text.splitlines()
                                text = "\n".join(lines[1:-1] if lines[-1] == "```" else lines[1:])
                            try:
                                return json.loads(text)
                            except json.JSONDecodeError:
                                logger.warning("Triage returned non-JSON: %s", text)
                                return {}
        finally:
            self.client.delete_agent(agent.id)
            logger.info("Deleted triage agent %s", agent.id)

        return {}
