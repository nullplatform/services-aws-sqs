variable "service_id" {
  type        = string
  description = "Nullplatform service ID"
}

variable "region" {
  type        = string
  description = "AWS region"
}

variable "queue_name" {
  type        = string
  description = "Full AWS queue name (np-<name>, plus .fifo for FIFO). Derived once by build_context and frozen in the service attributes"

  validation {
    condition     = can(regex("^np-[A-Za-z0-9_-]{1,72}(\\.fifo)?$", var.queue_name))
    error_message = "queue_name must be np-<name> with a 1-72 character name of letters, numbers, hyphens and underscores, optionally ending in .fifo"
  }
}

variable "fifo" {
  type        = bool
  description = "Whether the queue is FIFO. Must agree with the .fifo suffix of queue_name"

  validation {
    condition     = var.fifo == endswith(var.queue_name, ".fifo")
    error_message = "fifo must be true exactly when queue_name ends in .fifo"
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags applied to the queue"
}

variable "visibility_timeout_seconds" {
  type    = number
  default = 30

  validation {
    condition     = var.visibility_timeout_seconds >= 0 && var.visibility_timeout_seconds <= 43200
    error_message = "visibility_timeout_seconds must be between 0 and 43200"
  }
}

variable "message_retention_seconds" {
  type    = number
  default = 345600

  validation {
    condition     = var.message_retention_seconds >= 60 && var.message_retention_seconds <= 1209600
    error_message = "message_retention_seconds must be between 60 and 1209600"
  }
}

variable "delay_seconds" {
  type    = number
  default = 0

  validation {
    condition     = var.delay_seconds >= 0 && var.delay_seconds <= 900
    error_message = "delay_seconds must be between 0 and 900"
  }
}

variable "max_message_size_bytes" {
  type    = number
  default = 1048576

  validation {
    condition     = var.max_message_size_bytes >= 1024 && var.max_message_size_bytes <= 1048576
    error_message = "max_message_size_bytes must be between 1024 and 1048576"
  }
}

variable "receive_wait_time_seconds" {
  type    = number
  default = 0

  validation {
    condition     = var.receive_wait_time_seconds >= 0 && var.receive_wait_time_seconds <= 20
    error_message = "receive_wait_time_seconds must be between 0 and 20"
  }
}

variable "encryption_key_type" {
  type    = string
  default = "sse-sqs"

  validation {
    condition     = contains(["sse-sqs", "sse-kms"], var.encryption_key_type)
    error_message = "encryption_key_type must be sse-sqs or sse-kms"
  }
}

variable "kms_key_arn" {
  type        = string
  default     = ""
  description = "KMS key or alias ARN, required with sse-kms"

  validation {
    condition     = var.encryption_key_type != "sse-kms" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:(key/[A-Za-z0-9-]+|alias/[A-Za-z0-9/_-]+)$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key or alias ARN when encryption_key_type is sse-kms"
  }
}

variable "kms_data_key_reuse_seconds" {
  type    = number
  default = 300

  validation {
    condition     = var.kms_data_key_reuse_seconds >= 60 && var.kms_data_key_reuse_seconds <= 86400
    error_message = "kms_data_key_reuse_seconds must be between 60 and 86400"
  }
}

variable "send_principals" {
  type        = list(string)
  default     = []
  description = "Extra principals allowed to send, as ARNs. Empty means only the queue owner"
}

variable "receive_principals" {
  type        = list(string)
  default     = []
  description = "Extra principals allowed to receive, as ARNs. Empty means only the queue owner"
}

variable "redrive_allow" {
  type    = string
  default = "disabled"

  validation {
    condition     = contains(["disabled", "allow_all", "by_queue", "deny_all"], var.redrive_allow)
    error_message = "redrive_allow must be disabled, allow_all, by_queue or deny_all"
  }
}

variable "redrive_source_queue_arns" {
  type    = list(string)
  default = []

  validation {
    condition     = var.redrive_allow != "by_queue" || length(var.redrive_source_queue_arns) > 0
    error_message = "redrive_source_queue_arns must not be empty when redrive_allow is by_queue"
  }
}

variable "dlq_arn" {
  type        = string
  default     = ""
  description = "Dead-letter queue ARN. Empty disables the dead-letter queue"
}

variable "dlq_max_receives" {
  type    = number
  default = 10

  validation {
    condition     = var.dlq_max_receives >= 1 && var.dlq_max_receives <= 1000
    error_message = "dlq_max_receives must be between 1 and 1000"
  }
}
