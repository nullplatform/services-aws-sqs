provider "nullplatform" {
  api_key = var.np_api_key
}

module "service_definition_aws_sqs" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v8.1.0"

  nrn          = var.nrn
  service_name = "AWS SQS"
  service_path = "sqs"

  git_provider      = "local"
  local_specs_path  = var.local_specs_path
  repository_branch = "" # ignored in local mode, but the variable is required
}
