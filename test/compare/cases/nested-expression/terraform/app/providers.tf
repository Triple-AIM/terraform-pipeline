variable "sts" {
  default = "https://sts.amazonaws.com"
}

# The expression is inside a nested block.
provider "aws" {
  region = "us-east-1"
  endpoints {
    sts = var.sts
  }
}
