# A TeamMind server on Azure: one VM with a static public IP in its own resource group (or one you name), a network security
# group, a managed identity that may read the named Key Vault secrets and write blobs to the backup container,
# and the A record when a zone is given. olyvr-teammind/README.md says how to run it.

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "centralindia"
}

variable "key_vault" {
  description = "Name of the Key Vault (RBAC mode) holding the named secrets."
  type        = string
}

variable "key_vault_resource_group" {
  description = "The resource group that vault is in."
  type        = string
}

variable "dns_zone_resource_group" {
  description = "The resource group dns_zone is in, when dns_zone is set."
  type        = string
  default     = ""
}

variable "backup_storage_account" {
  description = "The storage account that holds backup_bucket (the container)."
  type        = string
}

variable "backup_resource_group" {
  description = "The resource group that storage account is in."
  type        = string
}

variable "resource_group" {
  description = "An existing resource group for the server's resources; empty makes one named after name."
  type        = string
  default     = ""
}

variable "artifacts_resource_group" {
  description = "For a bundle in Azure Blob storage (artifacts = https://<account>.blob.core.windows.net/...): the resource group of that account; empty means backup_resource_group."
  type        = string
  default     = ""
}

locals {
  cloud       = "azure"
  gcp_project = ""
  azure_vault = var.key_vault
  public_ip   = azurerm_public_ip.this.ip_address
  vm_id       = azurerm_linux_virtual_machine.this.id
  backup_url  = "https://${var.backup_storage_account}.blob.core.windows.net/${var.backup_bucket}"
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault
  resource_group_name = var.key_vault_resource_group
}

data "azurerm_storage_account" "backup" {
  name                = var.backup_storage_account
  resource_group_name = var.backup_resource_group
}

resource "azurerm_resource_group" "this" {
  count    = var.resource_group == "" ? 1 : 0
  name     = var.name
  location = var.location
}

data "azurerm_resource_group" "given" {
  count = var.resource_group == "" ? 0 : 1
  name  = var.resource_group
}

locals {
  rg_name     = var.resource_group == "" ? azurerm_resource_group.this[0].name : data.azurerm_resource_group.given[0].name
  rg_location = var.resource_group == "" ? azurerm_resource_group.this[0].location : data.azurerm_resource_group.given[0].location
  # A bundle in Azure Blob storage is read with the VM's identity: Storage Blob Data Reader on its container.
  artifacts_blob = regex("^(?:https://([a-z0-9]+)\\.blob\\.core\\.windows\\.net/([a-z0-9-]+)/)?", var.artifacts)
}

# A virtual network of its own: nothing else shares it, and the network security group below is the only way in.
resource "azurerm_virtual_network" "this" {
  name                = "${var.name}-vnet"
  location            = local.rg_location
  resource_group_name = local.rg_name
  address_space       = [var.vpc_cidr]
}

resource "azurerm_subnet" "this" {
  name                 = "${var.name}-subnet"
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.subnet_cidr]
}

resource "azurerm_public_ip" "this" {
  name                = var.name
  location            = local.rg_location
  resource_group_name = local.rg_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_security_group" "this" {
  name                = var.name
  location            = local.rg_location
  resource_group_name = local.rg_name

  security_rule {
    name                       = "ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.admin_cidrs
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "gate"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.gate_port)
    source_address_prefixes    = var.reader_cidrs
    destination_address_prefix = "*"
  }
  dynamic "security_rule" {
    for_each = var.tls_mode == "letsencrypt" ? [1] : []
    content {
      name                       = "acme"
      priority                   = 120
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "80"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_network_interface" "this" {
  name                = var.name
  location            = local.rg_location
  resource_group_name = local.rg_name
  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.this.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this.id
  }
}

resource "azurerm_network_interface_security_group_association" "this" {
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

data "azurerm_dns_zone" "this" {
  count               = var.dns_zone != "" ? 1 : 0
  name                = var.dns_zone
  resource_group_name = var.dns_zone_resource_group
}

resource "azurerm_dns_a_record" "a" {
  count               = var.dns_zone != "" ? 1 : 0
  name                = trimsuffix(var.domain, ".${var.dns_zone}")
  zone_name           = data.azurerm_dns_zone.this[0].name
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 300
  records             = [azurerm_public_ip.this.ip_address]
}

resource "azurerm_linux_virtual_machine" "this" {
  name                  = var.name
  location              = local.rg_location
  resource_group_name   = local.rg_name
  size                  = var.machine_type
  admin_username        = var.ssh_user
  network_interface_ids = [azurerm_network_interface.this.id]
  custom_data           = base64encode(local.cloud_init)

  admin_ssh_key {
    username   = var.ssh_user
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.disk_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  # Cloud-init reads custom data once, and a change would replace the VM (and its disk); rerun the bootstrap or -replace.
  lifecycle {
    ignore_changes = [custom_data]
    precondition {
      condition     = can(regex("^https://", var.artifacts))
      error_message = "On Azure, artifacts is an https:// folder (s3:// is read on AWS only, gs:// on Google Cloud only)."
    }
  }

  depends_on = [azurerm_dns_a_record.a]
}

# Read exactly the named secrets: Key Vault RBAC takes a secret's own resource id as scope.
resource "azurerm_role_assignment" "secrets" {
  for_each             = toset(compact([var.llm_key_secret, var.tls_secret, var.backup_remote_secret]))
  scope                = "${data.azurerm_key_vault.this.id}/secrets/${each.value}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.this.identity[0].principal_id
}

# Write blobs, never delete them: the built-in Blob Data Contributor can also delete, so a custom role. It reads
# too, since rclone's Azure backend HEADs the destination before and after each upload and fails on a 403; the sets
# are encrypted to keys the server doesn't hold, so reading them back gives it nothing new.
resource "azurerm_role_definition" "blob_writer" {
  name  = "${var.name}-blob-writer"
  scope = data.azurerm_storage_account.backup.id
  permissions {
    data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
    ]
  }
  assignable_scopes = [data.azurerm_storage_account.backup.id]
}

resource "azurerm_role_assignment" "backup" {
  scope              = "${data.azurerm_storage_account.backup.id}/blobServices/default/containers/${var.backup_bucket}"
  role_definition_id = azurerm_role_definition.blob_writer.role_definition_resource_id
  principal_id       = azurerm_linux_virtual_machine.this.identity[0].principal_id
}

data "azurerm_storage_account" "artifacts" {
  count               = local.artifacts_blob[0] != null ? 1 : 0
  name                = local.artifacts_blob[0]
  resource_group_name = var.artifacts_resource_group != "" ? var.artifacts_resource_group : var.backup_resource_group
}

resource "azurerm_role_assignment" "artifacts" {
  count                = local.artifacts_blob[0] != null ? 1 : 0
  scope                = "${data.azurerm_storage_account.artifacts[0].id}/blobServices/default/containers/${local.artifacts_blob[1]}"
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_linux_virtual_machine.this.identity[0].principal_id
}

locals {
  backup_bucket = local.backup_url
}
