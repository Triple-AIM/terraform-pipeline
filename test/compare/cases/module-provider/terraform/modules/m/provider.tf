provider "aws" {
  alias = "hidden"
  endpoints {
    sts = "https://sts.example.com"
  }
}
