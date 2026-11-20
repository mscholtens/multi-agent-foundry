# Executive Summary

## What this lab demonstrates

This lab shows how to build a multi-agent system where a local orchestrator coordinates two AI agents — running different model families — through a shared tool server, all provisioned on Azure and torn down after the demonstration.

## Setup

A LangGraph coordinator runs locally and processes IT helpdesk support tickets submitted as PDF files. For each ticket, the coordinator calls a **Triage agent** (GPT on Microsoft Foundry) that classifies the ticket and determines whether a knowledge base lookup is needed. If so, a **Responder agent** (Claude on Foundry) drafts a response — when Claude decides to look something up, it returns a tool-use request to the coordinator, which calls the MCP server and feeds the result back. The coordinator is the sole MCP client; the Triage agent makes no tool calls.

## Key patterns demonstrated

- **Multi-agent orchestration with conditional routing**: LangGraph routes each ticket along a different path based on triage output.
- **MCP client/server pattern**: A standalone FastMCP server exposes tools; the coordinator discovers them at startup via `tools/list` and is the sole caller — agents receive discovered schemas but make no MCP calls themselves.
- **Agentic tool use**: Claude decides autonomously when to call `lookup_kb`, receives the result, and incorporates it into its response.
- **Two model families on one platform**: GPT handles structured classification; Claude handles open-ended response generation — both deployed under the same Foundry project.
- **Disposable infrastructure**: Terraform provisions everything; numbered scripts build, run, and tear down the lab without manual steps.

## Infrastructure

Azure resources used: Cognitive Services (AI Services kind), Foundry project, two model deployments (GPT + Claude Haiku), Azure Container Registry, Container Apps environment and app. All provisioned and destroyed by shell scripts backed by Terraform.
