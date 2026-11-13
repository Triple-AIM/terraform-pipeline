variable "file" {}

locals {
  text = file("${path.module}/${var.file}")
}
