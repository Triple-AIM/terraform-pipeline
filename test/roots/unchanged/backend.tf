# This root manages nothing. So its plan never has changes, and a merge never
# applies it.
terraform {
  backend "local" {}
}
