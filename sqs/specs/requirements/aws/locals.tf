locals {
  iam_module_name = "requirements-sqs"

  iam_create = var.iam_create_role

  role_name            = var.role_name != "" ? var.role_name : "nullplatform_${var.cluster_name}_sqs_role"
  policies_name_prefix = var.policies_name_prefix != "" ? var.policies_name_prefix : "nullplatform_${var.cluster_name}"

  account_id = data.aws_caller_identity.current.account_id

  agent_role_arn = var.agent_role_arn != "" ? var.agent_role_arn : "arn:aws:iam::${local.account_id}:role/nullplatform-${var.cluster_name}-agent-role"

  iam_default_tags = merge(var.iam_resource_tags_json, {
    ManagedBy = "nullplatform-custom-scope-role"
    Module    = local.iam_module_name
  })

  policy_documents = {
    queues = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ManageQueues"
          Effect   = "Allow"
          Action   = ["sqs:*"]
          Resource = "arn:aws:sqs:*:${local.account_id}:${var.resource_name_prefix}*"
        },
        {
          Sid      = "AccountLevelReads"
          Effect   = "Allow"
          Action   = ["sqs:ListQueues"]
          Resource = "*"
        },
      ]
    })

    link_users = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid    = "ManageLinkUsers"
        Effect = "Allow"
        Action = [
          "iam:CreateUser",
          "iam:DeleteUser",
          "iam:GetUser",
          "iam:TagUser",
          "iam:UntagUser",
          "iam:ListUserTags",
          "iam:PutUserPolicy",
          "iam:GetUserPolicy",
          "iam:DeleteUserPolicy",
          "iam:ListUserPolicies",
          "iam:ListAttachedUserPolicies",
          "iam:ListGroupsForUser",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:ListAccessKeys",
        ]
        Resource = "arn:aws:iam::${local.account_id}:user/${var.resource_name_prefix}*"
      }]
    })

    kms = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid      = "UseQueueKeys"
        Effect   = "Allow"
        Action   = ["kms:DescribeKey", "kms:GenerateDataKey", "kms:Decrypt"]
        Resource = var.kms_key_arns
      }]
    })

    state = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "StateBucketLocation"
          Effect   = "Allow"
          Action   = ["s3:GetBucketLocation"]
          Resource = "arn:aws:s3:::${var.state_bucket_name}"
        },
        {
          Sid      = "ListStatePrefix"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:ListBucketVersions"]
          Resource = "arn:aws:s3:::${var.state_bucket_name}"
          Condition = {
            StringLike = { "s3:prefix" = ["services/sqs/*"] }
          }
        },
        {
          Sid    = "ManageStateObjects"
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:GetObjectVersion",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:DeleteObjectVersion",
          ]
          Resource = "arn:aws:s3:::${var.state_bucket_name}/services/sqs/*"
        },
      ]
    })
  }
}
