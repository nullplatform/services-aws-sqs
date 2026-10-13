# A key alias ARN cannot be the Resource of an IAM statement: resolve it to the key ARN.
data "aws_kms_key" "queue" {
  count  = var.kms_key_arn == "" ? 0 : 1
  key_id = var.kms_key_arn
}

resource "aws_iam_user" "link" {
  name = var.user_name

  tags = {
    "managed-by" = "nullplatform"
    "link-id"    = var.link_id
  }
}

resource "aws_iam_user_policy" "link" {
  name = "${var.user_name}-queue"
  user = aws_iam_user.link.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid    = "UseQueue"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
        ]
        Resource = var.queue_arn
      }],
      var.kms_key_arn == "" ? [] : [{
        Sid      = "UseQueueKey"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = data.aws_kms_key.queue[0].arn
      }],
    )
  })
}

resource "aws_iam_access_key" "link" {
  user = aws_iam_user.link.name
}
