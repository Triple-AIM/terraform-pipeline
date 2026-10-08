resource "terraform_data" "this" {
  input = "unchanged"
}

# The pipeline plans in a sandbox. So this code cannot read Terraform's own
# environment, where the credentials are. It also cannot read files the
# sandbox does not grant. Both paths exist on a hosted runner. So if one cannot
# be read, the sandbox held.
locals {
  environment = "/proc/self/environ"
  ungranted   = "/etc/passwd"
}

resource "terraform_data" "sandboxed" {
  lifecycle {
    precondition {
      condition     = !can(filebase64(local.environment))
      error_message = "Terraform code can read its own environment."
    }
    precondition {
      condition     = !can(file(local.ungranted))
      error_message = "Terraform code can read files the sandbox does not grant."
    }
  }
}
