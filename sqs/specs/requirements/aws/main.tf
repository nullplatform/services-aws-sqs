resource "aws_iam_role" "nullplatform_sqs" {
  count = local.iam_create ? 1 : 0

  name        = local.role_name
  description = "Permissions role assumed by the nullplatform agent role for the aws-sqs service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = concat([local.agent_role_arn], var.additional_agent_role_arns) }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.iam_default_tags
}

resource "aws_iam_policy" "this" {
  for_each = local.iam_create ? local.policy_documents : {}

  name        = "${local.policies_name_prefix}_sqs_${each.key}_policy"
  description = "${each.key} permissions for the nullplatform aws-sqs service"
  policy      = each.value

  tags = local.iam_default_tags
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = aws_iam_policy.this

  role       = aws_iam_role.nullplatform_sqs[0].name
  policy_arn = each.value.arn
}
