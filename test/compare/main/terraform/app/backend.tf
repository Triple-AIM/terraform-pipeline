terraform {
  backend "s3" {
    bucket = "state"
    key    = "app.tfstate"
    region = "us-east-1"
  }
}
