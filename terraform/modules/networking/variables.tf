variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "cluster_name" {
  type    = string
  default = "aks-devops-project"
}

variable "tags" {
  type    = map(string)
  default = {}
}