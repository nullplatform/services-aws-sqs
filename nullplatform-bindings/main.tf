provider "nullplatform" {
  api_key = var.np_api_key
}

module "service_definition_agent_association_aws_sqs" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v8.1.0"

  nrn            = var.nrn
  api_key        = var.np_api_key
  tags_selectors = var.agent_tags_selectors

  service_specification_slug   = data.terraform_remote_state.nullplatform.outputs.service_specification_slug
  repository_service_spec_repo = var.repository_name
  service_path                 = "sqs"
  base_clone_path              = pathexpand("~/.np")
}
