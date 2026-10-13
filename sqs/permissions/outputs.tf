output "user_name" {
  value       = aws_iam_user.link.name
  description = "IAM user created for this link"
}

output "access_key_id" {
  value       = aws_iam_access_key.link.id
  description = "Access key ID of the link user"
}

output "secret_access_key" {
  value       = aws_iam_access_key.link.secret
  sensitive   = true
  description = "Secret access key of the link user"
}
