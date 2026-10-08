# The pipeline plans and applies this root. Its module comes from a private
# repository. So each job must create a token from the config's GitHub App to
# install it.
module "pet" {
  source = "git::https://github.com/Triple-AIM/terraform-pipeline-test-module.git?ref=0cd256fe35b9b58b06a0152d17b0efb10133ac7a"
}

output "pet" {
  value = module.pet.name
}
