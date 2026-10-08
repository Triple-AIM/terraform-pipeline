# A root that the other cases do not plan. Its endpoint is on the default
# branch, so a case can try to borrow it.
terraform {
  backend "local" {}
}

provider "aws" {
  region = "us-east-1"
  endpoints {
    sts = "http://localhost:4566"
  }
}
