provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

terraform {
  backend "azurerm" {
    resource_group_name = "hpc_deployer"
    storage_account_name = "hpcdeployertfstate"
    container_name = "tfstate"
    key = "terraform.tfstate"
    subscription_id = var.subscription_id
  }
}

locals {
  common_tags = {
    Environment = "development"
    Project     = "hpc-deployer-demo"
    ManagedBy   = "Terraform"
  }
}

data "azurerm_subscription" "current" {}

data "azurerm_resource_group" "hpc_deployer_rg" {
  name = var.resource_group_name
}

# 2. Create an Azure Virtual Network (VNet)
resource "azurerm_virtual_network" "hpc_deployer_vnet" {
  name                = "hpc-deployer-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = data.azurerm_resource_group.hpc_deployer_rg.location
  resource_group_name = data.azurerm_resource_group.hpc_deployer_rg.name
  tags                = local.common_tags
}

# 3. Create an Azure Subnet
resource "azurerm_subnet" "hpc_deployer_subnet" {
  name                 = "hpc-deployer-subnet"
  resource_group_name  = data.azurerm_resource_group.hpc_deployer_rg.name
  virtual_network_name = azurerm_virtual_network.hpc_deployer_vnet.name
  address_prefixes     = ["10.0.1.0/24"] # CIDR block for the subnet
}

# 4. Create an Azure Storage Account
resource "azurerm_storage_account" "hpc_deployer_sa" {
  name                     = "hpcdeployer001"
  resource_group_name      = data.azurerm_resource_group.hpc_deployer_rg.name
  location                 = data.azurerm_resource_group.hpc_deployer_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = local.common_tags
}

resource "azurerm_network_interface" "nic" {
  name                = "${var.vm_name}-nic"
  location            = data.azurerm_resource_group.hpc_deployer_rg.location
  resource_group_name = data.azurerm_resource_group.hpc_deployer_rg.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.hpc_deployer_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_security_group" "cyclecloud_server_subnet_nsg" {
  name                = var.cyclecloud_server_subnet_nsg
  location            = data.azurerm_resource_group.hpc_deployer_rg.location
  resource_group_name = data.azurerm_resource_group.hpc_deployer_rg.name

  security_rule {
    name                       = "HTTP"
    priority                   = 1020
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "cyclecloud_server_subnet_nsg_assign" {
  subnet_id                 = azurerm_subnet.hpc_deployer_subnet.id
  network_security_group_id = azurerm_network_security_group.cyclecloud_server_subnet_nsg.id
}


resource "azurerm_linux_virtual_machine" "azure_cyclecloud_server_vm" {
  name                = var.vm_name
  resource_group_name = data.azurerm_resource_group.hpc_deployer_rg.name
  location            = data.azurerm_resource_group.hpc_deployer_rg.location
  size                = "Standard_D2s_v3"
  admin_username      = var.admin_username
  # admin_password      = var.admin_password
  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]
  disable_password_authentication = true
  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    name                 = "${var.vm_name}-osdisk"
    disk_size_gb         = 128
  }

  tags = local.common_tags
  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(templatefile("${path.module}/../scripts/setup.sh.tpl", {
    cyclecloud_version = var.cyclecloud_version
  }))
}

# Assign role to the managed ID
resource "azurerm_role_assignment" "acc_mi_contributor_role" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
  principal_id         = lookup(azurerm_linux_virtual_machine.azure_cyclecloud_server_vm.identity[0], "principal_id")
}

# Assign role to the managed ID
resource "azurerm_role_assignment" "acc_mi_storage_data_contributor_role" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = lookup(azurerm_linux_virtual_machine.azure_cyclecloud_server_vm.identity[0], "principal_id")
}

resource "azurerm_user_assigned_identity" "hpc_deployer_locker_mi" {
  name                = "hpc-deployer-cyclecloud-locker-mi"
  resource_group_name = data.azurerm_resource_group.hpc_deployer_rg.name
  location            = data.azurerm_resource_group.hpc_deployer_rg.location
}

# Role Assignment: Contributor
resource "azurerm_role_assignment" "blob_reader" {
  scope                = azurerm_storage_account.hpc_deployer_sa.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.hpc_deployer_locker_mi.principal_id
}

# Role Assignment: Storage Blob Data Contributor
resource "azurerm_role_assignment" "blob_data_contributor" {
  scope                = azurerm_storage_account.hpc_deployer_sa.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.hpc_deployer_locker_mi.principal_id
}

resource "azurerm_role_assignment" "hpc_deployer_locker_mi_reader_role" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.hpc_deployer_locker_mi.principal_id
}

# --- New Resources for Windows VM ---

# NSGs act as a virtual firewall to control inbound and outbound traffic. [15]
resource "azurerm_network_security_group" "hpc_deployer_windows_vm_nsg" {
  name                = "hpc-deployer-windows-vm-nsg"
  location            = data.azurerm_resource_group.hpc_deployer_rg.location
  resource_group_name = data.azurerm_resource_group.hpc_deployer_rg.name
  tags                = local.common_tags
}

# 7. Add an Inbound Security Rule to the NSG for RDP (Port 3389)
# This rule allows RDP access to the VM. For better security, replace "0.0.0.0/0"
resource "azurerm_network_security_rule" "rdp_rule" {
  name                        = "AllowRDP"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"      # Standard RDP port
  source_address_prefix       = "0.0.0.0/0" # WARNING: Allows RDP from any IP. Restrict this!
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.hpc_deployer_rg.name
  network_security_group_name = azurerm_network_security_group.hpc_deployer_windows_vm_nsg.name
}

resource "azurerm_network_security_rule" "outbound_8080_rule" {
  name                        = "AllowOutbound8080"
  priority                    = 101 # Must be unique and within 100-4096
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8080"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.hpc_deployer_rg.name
  network_security_group_name = azurerm_network_security_group.hpc_deployer_windows_vm_nsg.name
}

# 8. Create a Network Interface (NIC) for the VM
# The NIC connects the VM to the subnet and associates the public IP and NSG. [13, 14, 17]
resource "azurerm_network_interface" "hpc_deployer_windows_vm_nic" {
  name                = "hpc-deployer-windows-vm-nic"
  location            = data.azurerm_resource_group.hpc_deployer_rg.location
  resource_group_name = data.azurerm_resource_group.hpc_deployer_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.hpc_deployer_subnet.id
    private_ip_address_allocation = "Dynamic" # Or "Static" with a specified private_ip_address
  }
  tags = local.common_tags
}

# 9. Associate the Network Security Group with the Network Interface
# This applies the NSG rules to the NIC.
resource "azurerm_network_interface_security_group_association" "example_nic_nsg_association" {
  network_interface_id      = azurerm_network_interface.hpc_deployer_windows_vm_nic.id
  network_security_group_id = azurerm_network_security_group.hpc_deployer_windows_vm_nsg.id
}

# 10. Create the Windows Virtual Machine
resource "azurerm_windows_virtual_machine" "hpc_deployer_windows_vm" {
  name                = "hpc-windows-vm"
  resource_group_name = data.azurerm_resource_group.hpc_deployer_rg.name
  location            = data.azurerm_resource_group.hpc_deployer_rg.location
  size                = "Standard_D2s_v3" # VM size, choose based on requirements
  admin_username      = var.admin_username
  admin_password      = var.admin_password # Use a variable for sensitive data

  network_interface_ids = [
    azurerm_network_interface.hpc_deployer_windows_vm_nic.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter" // "2019-Datacenter" # Or 
    version   = "latest"
  }

  tags = local.common_tags
}


# --------- Bastion ------------
# 3. Create the AzureBastionSubnet
# This subnet is MANDATORY for Azure Bastion.
# It MUST be named "AzureBastionSubnet" and have a prefix of at least /26. [1, 4, 9]
resource "azurerm_subnet" "azure_bastion_subnet" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = data.azurerm_resource_group.hpc_deployer_rg.name
  virtual_network_name = azurerm_virtual_network.hpc_deployer_vnet.name
  address_prefixes     = ["10.0.2.0/26"] # /26 provides 64 IPs, sufficient for Bastion [9]
}

# 4. Create a Public IP Address for Azure Bastion
# The Public IP must be Standard SKU and Static allocation. [1, 9, 10]
resource "azurerm_public_ip" "bastion_public_ip" {
  name                = "hpc-bastion-public-ip"
  resource_group_name = data.azurerm_resource_group.hpc_deployer_rg.name
  location            = data.azurerm_resource_group.hpc_deployer_rg.location
  allocation_method   = "Static"
  sku                 = "Standard" # Required for Azure Bastion [1, 9]
  tags                = local.common_tags
}

# 5. Create the Azure Bastion Host
# This resource deploys the managed Bastion service into the dedicated subnet. [1, 2]
resource "azurerm_bastion_host" "hpc_bastion" {
  name                = "hpc-azure-bastion-host"
  location            = data.azurerm_resource_group.hpc_deployer_rg.location
  resource_group_name = data.azurerm_resource_group.hpc_deployer_rg.name
  sku                 = "Standard" # Standard SKU offers more features like file transfer, host scaling [1, 9]

  ip_configuration {
    name                 = "ipconfig1"
    subnet_id            = azurerm_subnet.azure_bastion_subnet.id
    public_ip_address_id = azurerm_public_ip.bastion_public_ip.id
  }

  tags = local.common_tags
}
