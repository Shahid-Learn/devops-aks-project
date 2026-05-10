variable "location"            { type = string }
variable "resource_group_name" { type = string }
variable "cluster_name"        { type = string }
variable "tenant_id"           { type = string }
variable "aks_oidc_issuer_url" { type = string }
variable "tags"                { 
    type = map(string) 
    default = {} 
    }