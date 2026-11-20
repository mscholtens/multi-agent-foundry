variable "subscription_id" {
  type        = string
  description = "Azure subscription ID"
}

variable "tenant_id" {
  type        = string
  description = "Azure tenant ID"
}

variable "region" {
  type        = string
  default     = "swedencentral"
  description = "Azure region. Must support both GPT (Standard/GlobalStandard) and Claude Global Standard."
}

variable "gpt_model" {
  type        = string
  default     = "gpt-4.1-mini"
  description = "GPT model name for the triage deployment."
}

variable "gpt_model_version" {
  type        = string
  default     = "2025-04-14"
}

variable "claude_model" {
  type        = string
  default     = "claude-haiku-5-5"
  description = "Claude model name for the responder deployment."
}

variable "acr_password" {
  type        = string
  sensitive   = true
  default     = ""
  description = "ACR admin password for pulling the MCP server image. Fetched via az acr credential show and passed by 02_deploy_mcp_server.sh. Empty during first apply and teardowns."
}

variable "image_tag" {
  type        = string
  default     = ""
  description = "Container image tag/digest from ACR build. Empty on first apply (Container App not created yet)."
}
