# The self-test's claims read this root's plan on every change. The pipeline
# plans a root when a path its code names changes. This names the
# repository's top directory, so every change plans it.
locals {
  repository = "${path.root}/../../.."
}
