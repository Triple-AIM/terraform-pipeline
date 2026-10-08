variable "profile" {
  default = "default"
}

provider "aws" {
  region  = "us-east-1"
  profile = var.profile
}
