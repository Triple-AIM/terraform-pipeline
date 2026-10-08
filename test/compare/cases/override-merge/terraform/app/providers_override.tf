# This block matches the one in terraform/local. Terraform merges it into
# this root's own provider block, so the root's credentials would go to that
# endpoint.
provider "aws" {
  endpoints {
    sts = "http://localhost:4566"
  }
}
