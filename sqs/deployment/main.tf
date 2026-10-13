data "aws_caller_identity" "current" {}

locals {
  common_tags = merge(var.tags, {
    "managed-by" = "nullplatform"
    "service-id" = var.service_id
  })

  use_kms         = var.encryption_key_type == "sse-kms"
  owner_principal = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"

  send_actions = ["sqs:SendMessage"]
  receive_actions = [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:ChangeMessageVisibility",
    "sqs:GetQueueAttributes",
  ]
}

resource "aws_sqs_queue" "queue" {
  name       = var.queue_name
  fifo_queue = var.fifo

  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  delay_seconds              = var.delay_seconds
  max_message_size           = var.max_message_size_bytes
  receive_wait_time_seconds  = var.receive_wait_time_seconds

  sqs_managed_sse_enabled           = local.use_kms ? null : true
  kms_master_key_id                 = local.use_kms ? var.kms_key_arn : null
  kms_data_key_reuse_period_seconds = local.use_kms ? var.kms_data_key_reuse_seconds : null

  tags = local.common_tags
}

resource "aws_sqs_queue_policy" "queue" {
  queue_url = aws_sqs_queue.queue.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "OwnerSend"
          Effect    = "Allow"
          Principal = { AWS = local.owner_principal }
          Action    = local.send_actions
          Resource  = aws_sqs_queue.queue.arn
        },
        {
          Sid       = "OwnerReceive"
          Effect    = "Allow"
          Principal = { AWS = local.owner_principal }
          Action    = local.receive_actions
          Resource  = aws_sqs_queue.queue.arn
        },
      ],
      length(var.send_principals) > 0 ? [{
        Sid       = "PrincipalsSend"
        Effect    = "Allow"
        Principal = { AWS = var.send_principals }
        Action    = local.send_actions
        Resource  = aws_sqs_queue.queue.arn
      }] : [],
      length(var.receive_principals) > 0 ? [{
        Sid       = "PrincipalsReceive"
        Effect    = "Allow"
        Principal = { AWS = var.receive_principals }
        Action    = local.receive_actions
        Resource  = aws_sqs_queue.queue.arn
      }] : [],
    )
  })
}

resource "aws_sqs_queue_redrive_policy" "queue" {
  count = var.dlq_arn == "" ? 0 : 1

  queue_url = aws_sqs_queue.queue.url
  redrive_policy = jsonencode({
    deadLetterTargetArn = var.dlq_arn
    maxReceiveCount     = var.dlq_max_receives
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "queue" {
  count = var.redrive_allow == "disabled" ? 0 : 1

  queue_url = aws_sqs_queue.queue.url
  redrive_allow_policy = var.redrive_allow == "by_queue" ? jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = var.redrive_source_queue_arns
    }) : jsonencode({
    redrivePermission = var.redrive_allow == "allow_all" ? "allowAll" : "denyAll"
  })
}
