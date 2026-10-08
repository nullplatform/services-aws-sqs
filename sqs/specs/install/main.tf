provider "nullplatform" {
  api_key = var.api_key
}

module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v8.1.0"

  nrn                    = var.nrn
  service_name           = var.service_name
  service_path           = var.service_path
  git_provider           = var.git_provider
  local_specs_path       = var.local_specs_path
  repository_org         = var.repository_org
  repository_name        = var.repository_name
  repository_branch      = var.repository_branch
  repository_ref_type    = var.repository_ref_type
  repository_token       = var.repository_token
  available_links        = var.available_links
  extra_visibile_to_nrns = var.extra_visible_to_nrns
  dimensions             = var.dimensions
}

module "agent_association" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v8.1.0"

  nrn                          = var.nrn
  api_key                      = var.api_key
  tags_selectors               = var.agent_tags_selectors
  service_specification_slug   = module.service_definition.service_specification_slug
  repository_service_spec_repo = var.repository_name
  service_path                 = var.service_path
  base_clone_path              = pathexpand(var.base_clone_path)
  description                  = var.channel_description
}
