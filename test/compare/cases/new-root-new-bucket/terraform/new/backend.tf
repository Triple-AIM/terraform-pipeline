terraform {
  backend "s3" {
    bucket = "elsewhere"
    key    = "new.tfstate"
    region = "us-east-1"
  }
}
