variable "name" {
  default = "a"
}

locals {
  policy = file("${path.module}/../../policies/read.json")
  # Only the directory is known.
  chosen = file("${path.module}/../../files/${var.name}.json")
}

# A relative path, passed to a module that reads it from its own directory.
module "reader" {
  source = "../../modules/reader"
  file   = "../shared/note.txt"
}
