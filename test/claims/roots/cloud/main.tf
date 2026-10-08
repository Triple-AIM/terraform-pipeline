terraform {
  cloud {
    organization = "example"
    workspaces {
      name = "example"
    }
  }
}
