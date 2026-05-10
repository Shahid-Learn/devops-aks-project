variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "cluster_name" { type = string }
variable "kubernetes_version" { type = string }
variable "node_vm_size_system" { type = string }
variable "node_vm_size_app" { type = string }
variable "subnet_id" { type = string }
variable "acr_id" { type = string }
variable "tenant_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}