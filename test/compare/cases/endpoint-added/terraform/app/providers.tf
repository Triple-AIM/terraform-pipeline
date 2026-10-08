provider "aws" {
  region = "us-east-1"
  endpoints {
    sts = "https://sts.example.com"
  }
}
