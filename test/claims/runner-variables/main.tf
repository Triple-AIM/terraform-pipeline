# The self-test plans this in the sandbox. The external data source runs a
# program, as a provider that can run programs would. The program gets the
# environment that Terraform passes on. It fails if any condition below does
# not hold.
terraform {
  required_providers {
    external = {
      source = "hashicorp/external"
    }
  }
}

data "external" "environment" {
  program = ["sh", "${path.module}/environment.sh"]
}

resource "terraform_data" "checked" {
  lifecycle {
    # Without this check, a program with no environment at all would pass.
    precondition {
      condition     = data.external.environment.result.marker == "passed on"
      error_message = "The program did not get the variable the self-test set, so the check below proves nothing."
    }
    precondition {
      condition     = data.external.environment.result.runner == "0"
      error_message = "A program that Terraform started got some of the runner's own variables."
    }
  }
}
