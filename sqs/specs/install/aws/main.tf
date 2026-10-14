################################################################################
# Install: registers the AWS SQS service definition (service and link
# specifications) and its agent association (the notification channel that
# routes the service's actions to an agent) on a nullplatform account.
#
# This is a reference to copy into your own infrastructure, not a module to
# apply from here: it declares no provider. Configure the nullplatform provider
# in the root module that uses it.
#
# The IAM role the agent assumes lives in ../../requirements/aws and is applied
# separately, in the AWS account that holds the queues.
#
# The agent association takes no API key: nullplatform creates and manages the
# notification channel's credential, scoped to dispatching commands to agents.
# The identity running the apply must be able to assign the
# controlplane:agent-dispatcher role (admin, ops or secops).
################################################################################

locals {
  service_path    = "sqs"
  available_links = ["connect"]
}

module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v8.7.0"

  nrn                 = var.nrn
  service_name        = var.service_name
  service_path        = local.service_path
  available_links     = local.available_links
  repository_org      = var.repository_org
  repository_name     = var.repository_name
  repository_branch   = var.repository_branch
  repository_ref_type = var.repository_ref_type
  repository_token    = var.repository_token
}

module "service_definition_agent_association" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v8.7.0"

  nrn                          = var.nrn
  tags_selectors               = var.tags_selectors
  service_specification_slug   = module.service_definition.service_specification_slug
  repository_service_spec_repo = var.repository_name
  service_path                 = local.service_path
  base_clone_path              = var.base_clone_path
  description                  = "AWS SQS service actions"
}
