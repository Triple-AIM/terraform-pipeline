terraform {
  backend "s3" {
    bucket = "state"
    key    = "new.tfstate"
    region = "us-east-1"
  }
}
