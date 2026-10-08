output "service_specification_id" {
  value       = module.service_definition.service_specification_id
  description = "ID of the registered service specification"
}

output "service_specification_slug" {
  value       = module.service_definition.service_specification_slug
  description = "Slug of the registered service specification"
}

output "notification_channel_id" {
  value       = module.agent_association.id
  description = "ID of the notification channel routing this service's actions to the agent"
}
