output "service_specification_id" {
  description = "ID of the registered AWS SQS service specification."
  value       = module.service_definition.service_specification_id
}

output "service_specification_slug" {
  description = "Slug of the registered AWS SQS service specification."
  value       = module.service_definition.service_specification_slug
}
