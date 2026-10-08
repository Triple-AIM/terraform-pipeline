variable "bucket" {
  default = "state"
}

data "terraform_remote_state" "other" {
  backend = "s3"
  config = {
    bucket = var.bucket
    key    = "other.tfstate"
    region = "us-east-1"
  }
}
