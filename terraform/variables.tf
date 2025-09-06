variable "vm_name" {
  default = "hpc-cyclecloud-cluster-vm"
}
variable "admin_username" {
  type      = string
  sensitive = true
  default   = "azureuser"
}

variable "admin_password" {
  description = "Admin password for the VM"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "VM SSH public key"
  type        = string
  sensitive   = true
}

variable "machine_type" {
  description = "The Azure Machine Type for the CycleCloud VM"
  default     = "Standard_D2s_v3"
}

variable "cyclecloud_server_subnet_nsg" {
  default = "cyclecloud_server_subnet_nsg"
}

variable "artifactory_username" {
  type      = string
  sensitive = true
  default   = "value"
}

variable "artifactory_password" {
  type      = string
  sensitive = true
  default   = "value"
}

variable "cyclecloud_version" {
  default = "8.7.2-3398"
  type    = string
}