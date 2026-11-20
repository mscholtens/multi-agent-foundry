output "resource_group_name" {
  value = azapi_resource.rg.name
}

output "foundry_account_name" {
  value = azapi_resource.foundry_account.name
}

output "foundry_endpoint" {
  value = "https://${var.region}.api.cognitive.microsoft.com/"
}

output "foundry_project_endpoint" {
  value = try(azapi_resource.foundry_project.output.properties.endpoints["AI Foundry API"], "")
}

output "foundry_api_key" {
  sensitive = true
  # Azure Cognitive Services keys are NOT in the resource GET response.
  # Script 01 fetches the real key via: az cognitiveservices account keys list
  value = ""
}

output "gpt_deployment_name" {
  value = azapi_resource.gpt_deployment.name
}

output "claude_deployment_name" {
  value = "${var.claude_model}-deployment"
}

output "acr_name" {
  value = azapi_resource.acr.name
}

output "acr_login_server" {
  value = try(azapi_resource.acr.output.properties.loginServer, "")
}

output "mcp_url" {
  value = var.image_tag != "" ? try("https://${azapi_resource.ca[0].output.properties.configuration.ingress.fqdn}/mcp", "") : ""
}

output "mcp_api_key" {
  sensitive = true
  value     = random_password.mcp_api_key.result
}
