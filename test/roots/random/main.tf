module "pet" {
  source = "../../modules/pet"
}

output "pet" {
  value = module.pet.name
}
