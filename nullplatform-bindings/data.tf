data "terraform_remote_state" "nullplatform" {
  backend = "local"
  config = {
    path = "../nullplatform/terraform.tfstate"
  }
}
