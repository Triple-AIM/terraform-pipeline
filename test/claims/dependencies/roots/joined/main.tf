locals {
  policy = file(join("/", [path.module, "..", "..", "policies", "read.json"]))
}
