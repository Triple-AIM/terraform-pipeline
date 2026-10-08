terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
    }
  }
}

resource "random_pet" "this" {}

output "name" {
  value = random_pet.this.id
}
