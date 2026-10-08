# Its lock file was made by `terraform init` on macOS, with no other step. So
# it has no hash that is only for Linux. The self-test installs it on Linux
# and validates and plans it, as the pipeline does.
terraform {
  backend "local" {}
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }
}
