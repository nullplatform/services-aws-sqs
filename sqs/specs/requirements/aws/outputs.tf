output "permissions_role_arn" {
  description = "ARN of the role the agent assumes to operate this service. Publish it to the nullplatform AWS IAM provider under selector \"sqs\"."
  value       = local.iam_create ? aws_iam_role.nullplatform_sqs[0].arn : ""
}

output "permissions_role_name" {
  description = "Name of the permissions role"
  value       = local.iam_create ? aws_iam_role.nullplatform_sqs[0].name : ""
}

output "permissions_role_id" {
  description = "ID of the permissions role"
  value       = local.iam_create ? aws_iam_role.nullplatform_sqs[0].id : ""
}
