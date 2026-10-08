# The self-test installs this provider, then checks where Terraform put it.
terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
    }
  }
}
