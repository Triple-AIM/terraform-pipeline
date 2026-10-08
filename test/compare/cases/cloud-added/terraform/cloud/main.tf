# A new root whose only setting is a cloud block that nothing on the default
# branch has.
terraform {
  cloud {
    hostname     = "tfe.example.com"
    organization = "example"
  }
}
