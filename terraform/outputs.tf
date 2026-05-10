output "aks_cluster_name" {
  value = module.aks.cluster_name
}

output "aks_cluster_endpoint" {
  value     = module.aks.kube_config.0.host
  sensitive = true
}

output "acr_login_server" {
  value = module.acr.login_server
}

output "oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

output "keyvault_uri" {
  value = module.keyvault.vault_uri
}

output "get_credentials_command" {
  value = "az aks get-credentials --resource-group ${var.resource_group_name} --name ${module.aks.cluster_name} --overwrite-existing"
}