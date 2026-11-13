variable "dir" {}

locals {
  secrets = file("${var.dir}/../secrets.json")
}
