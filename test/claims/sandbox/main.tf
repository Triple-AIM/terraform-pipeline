# The self-test plans this in the sandbox. It fails if any condition below
# does not hold.

variable "home_file" {
  description = "A file the self-test writes in the home directory."
  type        = string
}

variable "runner_temp_file" {
  description = "A file the self-test writes in the runner's temporary directory, outside Terraform's own working files."
  type        = string
}

locals {
  environment = "/proc/self/environ"
  linked      = "${path.module}/environ-link"
  ungranted   = "/etc/passwd"
  granted     = "${path.module}/main.tf"
}

resource "terraform_data" "sandboxed" {
  lifecycle {
    # Without this check, the refusals below could just mean that nothing can
    # be read.
    precondition {
      condition     = can(file(local.granted))
      error_message = "Terraform code cannot read its own configuration, so the checks below prove nothing."
    }
    precondition {
      condition     = !can(filebase64(local.environment))
      error_message = "Terraform code can read its own environment."
    }
    precondition {
      condition     = !can(filebase64(local.linked))
      error_message = "Terraform code can read its own environment through a link in the workspace."
    }
    precondition {
      condition     = !can(file(var.home_file))
      error_message = "Terraform code can read the home directory."
    }
    precondition {
      condition     = !can(file(var.runner_temp_file))
      error_message = "Terraform code can read the runner's temporary files."
    }
    precondition {
      condition     = !can(file(local.ungranted))
      error_message = "Terraform code can read files the sandbox does not grant."
    }
  }
}
