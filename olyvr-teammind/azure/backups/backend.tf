# State lives in an Azure Storage blob container (versioned, locked with a blob lease), read with your Entra ID login.
# The account, container and key come from a backend.hcl you keep next to this file (git-ignored;
# backend.hcl.example shows it): terraform init -backend-config=backend.hcl
terraform {
  backend "azurerm" {}
}
