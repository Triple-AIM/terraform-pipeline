# The claims job does not allow hashicorp/null. So `terraform init` must
# refuse this.
terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}
