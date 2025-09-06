# Output the names of the created resources
# These outputs can be viewed after 'terraform apply' is successfully executed.
output "resource_group_name" {
  value = azurerm_resource_group.hpc_deployer_rg.name
}

output "virtual_network_name" {
  value = azurerm_virtual_network.hpc_deployer_vnet.name
}

output "subnet_name" {
  value = azurerm_subnet.hpc_deployer_subnet.name
}

output "storage_account_name" {
  value = azurerm_storage_account.hpc_deployer_sa.name
}

# Output the VM name
output "windows_vm_name" {
  value       = azurerm_windows_virtual_machine.hpc_deployer_windows_vm.name
  description = "The name of the Windows VM"
}

# Output the Public IP address of the Bastion Host
output "bastion_public_ip_address" {
  value       = azurerm_public_ip.bastion_public_ip.ip_address
  description = "The Public IP address of the Azure Bastion Host."
}

# Output the Bastion Host name
output "bastion_host_name" {
  value       = azurerm_bastion_host.hpc_bastion.name
  description = "The name of the Azure Bastion Host."
}

