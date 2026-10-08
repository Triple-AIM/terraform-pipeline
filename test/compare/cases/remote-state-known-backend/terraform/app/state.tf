# The same backend as this root's own, with another key. The key is a safe
# setting, so this can be planned.
data "terraform_remote_state" "other" {
  backend = "s3"
  config = {
    bucket = "state"
    key    = "other.tfstate"
    region = "us-east-1"
  }
}
