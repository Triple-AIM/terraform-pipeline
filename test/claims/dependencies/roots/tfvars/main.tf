variable "values" {}

locals {
  values = file(var.values)
}
