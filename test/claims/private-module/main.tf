# The self-test runs the settings check on this root. Its module comes from a
# private repository with git. So the module can only be installed with a
# token.
module "pet" {
  source = "git::https://github.com/Triple-AIM/terraform-pipeline-test-module.git?ref=0cd256fe35b9b58b06a0152d17b0efb10133ac7a"
}
