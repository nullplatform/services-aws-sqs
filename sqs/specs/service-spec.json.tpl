{
  "name": "AWS SQS",
  "slug": "aws-sqs",
  "type": "dependency",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "use_default_naming": false,
  "use_managed_actions": false,
  "available_links": [
    "create-aws-sqs-link"
  ],
  "selectors": {
    "category": "Messaging",
    "imported": false,
    "provider": "AWS",
    "sub_category": "Queue"
  },
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "additionalProperties": false,
      "required": ["queue_type", "name"],
      "uiSchema": {
        "type": "VerticalLayout",
        "elements": [
          { "type": "Control", "scope": "#/properties/queue_type", "options": { "format": "radio" } },
          { "type": "Control", "scope": "#/properties/name" },
          {
            "type": "Categorization",
            "options": { "collapsable": { "label": "CONFIGURATION", "collapsed": false } },
            "elements": [
              {
                "type": "Category",
                "label": "Queue",
                "elements": [
                  { "type": "Control", "scope": "#/properties/visibility_timeout_value" },
                  { "type": "Control", "scope": "#/properties/visibility_timeout_unit", "options": { "format": "radio" } },
                  { "type": "Control", "scope": "#/properties/message_retention_value" },
                  { "type": "Control", "scope": "#/properties/message_retention_unit", "options": { "format": "radio" } },
                  { "type": "Control", "scope": "#/properties/delivery_delay_value" },
                  { "type": "Control", "scope": "#/properties/delivery_delay_unit", "options": { "format": "radio" } },
                  { "type": "Control", "scope": "#/properties/max_message_size_kib" },
                  { "type": "Control", "scope": "#/properties/receive_wait_time_seconds" }
                ]
              },
              {
                "type": "Category",
                "label": "Encryption",
                "elements": [
                  { "type": "Control", "scope": "#/properties/encryption" },
                  { "type": "Control", "scope": "#/properties/encryption_key_type", "options": { "format": "radio" } },
                  {
                    "type": "Control",
                    "scope": "#/properties/kms_key_arn",
                    "rule": { "effect": "SHOW", "condition": { "scope": "#/properties/encryption_key_type", "schema": { "const": "sse-kms" } } }
                  },
                  {
                    "type": "Control",
                    "scope": "#/properties/data_key_reuse_value",
                    "rule": { "effect": "SHOW", "condition": { "scope": "#/properties/encryption_key_type", "schema": { "const": "sse-kms" } } }
                  },
                  {
                    "type": "Control",
                    "scope": "#/properties/data_key_reuse_unit",
                    "options": { "format": "radio" },
                    "rule": { "effect": "SHOW", "condition": { "scope": "#/properties/encryption_key_type", "schema": { "const": "sse-kms" } } }
                  }
                ]
              },
              {
                "type": "Category",
                "label": "Access policy",
                "elements": [
                  { "type": "Control", "scope": "#/properties/send_access", "options": { "format": "radio" } },
                  {
                    "type": "Control",
                    "scope": "#/properties/send_principals",
                    "rule": { "effect": "SHOW", "condition": { "scope": "#/properties/send_access", "schema": { "const": "principals" } } }
                  },
                  { "type": "Control", "scope": "#/properties/receive_access", "options": { "format": "radio" } },
                  {
                    "type": "Control",
                    "scope": "#/properties/receive_principals",
                    "rule": { "effect": "SHOW", "condition": { "scope": "#/properties/receive_access", "schema": { "const": "principals" } } }
                  }
                ]
              },
              {
                "type": "Category",
                "label": "Redrive allow policy",
                "elements": [
                  { "type": "Control", "scope": "#/properties/redrive_allow", "options": { "format": "radio" } },
                  {
                    "type": "Control",
                    "scope": "#/properties/redrive_source_queues",
                    "rule": { "effect": "SHOW", "condition": { "scope": "#/properties/redrive_allow", "schema": { "const": "by_queue" } } }
                  }
                ]
              },
              {
                "type": "Category",
                "label": "Dead-letter queue",
                "elements": [
                  { "type": "Control", "scope": "#/properties/dlq_enabled", "options": { "format": "radio" } },
                  {
                    "type": "Control",
                    "scope": "#/properties/dlq_arn",
                    "rule": { "effect": "SHOW", "condition": { "scope": "#/properties/dlq_enabled", "schema": { "const": "enabled" } } }
                  },
                  {
                    "type": "Control",
                    "scope": "#/properties/dlq_max_receives",
                    "rule": { "effect": "SHOW", "condition": { "scope": "#/properties/dlq_enabled", "schema": { "const": "enabled" } } }
                  }
                ]
              }
            ]
          },
          { "type": "Control", "scope": "#/properties/tags" }
        ]
      },
      "properties": {
        "aws_region": {
          "type": "string",
          "title": "AWS Region",
          "config": "aws.region",
          "visibleOn": [],
          "editableOn": [],
          "description": "Region where the queue is created (taken from the account configuration)"
        },
        "queue_type": {
          "type": "string",
          "title": "Queue type",
          "default": "standard",
          "oneOf": [
            { "const": "standard", "title": "Standard: at-least-once delivery, best-effort ordering" },
            { "const": "fifo", "title": "FIFO: exactly-once processing, strict ordering" }
          ],
          "description": "Cannot be changed after creation.",
          "editableOn": ["create"],
          "order": 1
        },
        "name": {
          "type": "string",
          "title": "Name",
          "pattern": "^[A-Za-z0-9_-]{1,72}$",
          "description": "Letters, numbers, hyphens and underscores, up to 72 characters. The queue is created in AWS as np-<name> (np-<name>.fifo for FIFO). Cannot be changed after creation.",
          "editableOn": ["create"],
          "order": 2
        },
        "visibility_timeout_value": {
          "type": "integer",
          "title": "Visibility timeout",
          "default": 30,
          "minimum": 0,
          "maximum": 43200,
          "description": "How long a received message stays hidden from other consumers. From 0 seconds to 12 hours.",
          "editableOn": ["create", "update"],
          "order": 3
        },
        "visibility_timeout_unit": {
          "type": "string",
          "title": "Visibility timeout unit",
          "default": "seconds",
          "oneOf": [
            { "const": "seconds", "title": "Seconds" },
            { "const": "minutes", "title": "Minutes" },
            { "const": "hours", "title": "Hours" }
          ],
          "editableOn": ["create", "update"],
          "order": 4
        },
        "message_retention_value": {
          "type": "integer",
          "title": "Message retention period",
          "default": 4,
          "minimum": 1,
          "maximum": 1209600,
          "description": "How long SQS keeps a message that was not deleted. From 1 minute to 14 days.",
          "editableOn": ["create", "update"],
          "order": 5
        },
        "message_retention_unit": {
          "type": "string",
          "title": "Message retention unit",
          "default": "days",
          "oneOf": [
            { "const": "seconds", "title": "Seconds" },
            { "const": "minutes", "title": "Minutes" },
            { "const": "hours", "title": "Hours" },
            { "const": "days", "title": "Days" }
          ],
          "editableOn": ["create", "update"],
          "order": 6
        },
        "delivery_delay_value": {
          "type": "integer",
          "title": "Delivery delay",
          "default": 0,
          "minimum": 0,
          "maximum": 900,
          "description": "How long a new message stays invisible to consumers. From 0 seconds to 15 minutes.",
          "editableOn": ["create", "update"],
          "order": 7
        },
        "delivery_delay_unit": {
          "type": "string",
          "title": "Delivery delay unit",
          "default": "seconds",
          "oneOf": [
            { "const": "seconds", "title": "Seconds" },
            { "const": "minutes", "title": "Minutes" }
          ],
          "editableOn": ["create", "update"],
          "order": 8
        },
        "max_message_size_kib": {
          "type": "integer",
          "title": "Maximum message size (KiB)",
          "default": 1024,
          "minimum": 1,
          "maximum": 1024,
          "description": "Largest message the queue accepts, from 1 KiB to 1024 KiB.",
          "editableOn": ["create", "update"],
          "order": 9
        },
        "receive_wait_time_seconds": {
          "type": "integer",
          "title": "Receive message wait time (seconds)",
          "default": 0,
          "minimum": 0,
          "maximum": 20,
          "description": "Long polling wait, from 0 to 20 seconds. 0 means short polling.",
          "editableOn": ["create", "update"],
          "order": 10
        },
        "encryption": {
          "type": "string",
          "title": "Encryption",
          "default": "Enabled",
          "readOnly": true,
          "description": "Server-side encryption is always on.",
          "editableOn": [],
          "order": 11
        },
        "encryption_key_type": {
          "type": "string",
          "title": "Encryption key type",
          "default": "sse-sqs",
          "oneOf": [
            { "const": "sse-sqs", "title": "Amazon SQS key (SSE-SQS): a key SQS creates, manages and uses for you" },
            { "const": "sse-kms", "title": "AWS Key Management Service key (SSE-KMS): a key protected by AWS KMS" }
          ],
          "editableOn": ["create", "update"],
          "order": 12
        },
        "kms_key_arn": {
          "type": "string",
          "title": "KMS key ARN",
          "pattern": "^$|^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:(key/[A-Za-z0-9-]+|alias/[A-Za-z0-9/_-]+)$",
          "description": "ARN of the KMS key or alias that encrypts the queue, for example arn:aws:kms:us-east-1:123456789012:key/<id>. Applications linked to this queue are granted kms:GenerateDataKey and kms:Decrypt on it; the key policy must allow them.",
          "editableOn": ["create", "update"],
          "order": 13
        },
        "data_key_reuse_value": {
          "type": "integer",
          "title": "Data key reuse period",
          "default": 5,
          "minimum": 1,
          "maximum": 86400,
          "description": "How long SQS reuses a data key before asking KMS again. From 1 minute to 24 hours.",
          "editableOn": ["create", "update"],
          "order": 14
        },
        "data_key_reuse_unit": {
          "type": "string",
          "title": "Data key reuse unit",
          "default": "minutes",
          "oneOf": [
            { "const": "minutes", "title": "Minutes" },
            { "const": "hours", "title": "Hours" }
          ],
          "editableOn": ["create", "update"],
          "order": 15
        },
        "send_access": {
          "type": "string",
          "title": "Who can send messages",
          "default": "owner",
          "oneOf": [
            { "const": "owner", "title": "Only the queue owner" },
            { "const": "principals", "title": "Only the specified AWS accounts, IAM users and roles" }
          ],
          "editableOn": ["create", "update"],
          "order": 16
        },
        "send_principals": {
          "type": "string",
          "title": "Accounts, users and roles that can send",
          "description": "Comma-separated AWS account IDs or IAM user/role ARNs, for example 123456789012,arn:aws:iam::123456789012:user/SqsUser",
          "editableOn": ["create", "update"],
          "order": 17
        },
        "receive_access": {
          "type": "string",
          "title": "Who can receive messages",
          "default": "owner",
          "oneOf": [
            { "const": "owner", "title": "Only the queue owner" },
            { "const": "principals", "title": "Only the specified AWS accounts, IAM users and roles" }
          ],
          "editableOn": ["create", "update"],
          "order": 18
        },
        "receive_principals": {
          "type": "string",
          "title": "Accounts, users and roles that can receive",
          "description": "Comma-separated AWS account IDs or IAM user/role ARNs, for example 123456789012,arn:aws:iam::123456789012:role/Worker",
          "editableOn": ["create", "update"],
          "order": 19
        },
        "redrive_allow": {
          "type": "string",
          "title": "Redrive allow policy",
          "description": "Which source queues can use this queue as their dead-letter queue. Allow all: any queue in the same account and region. By queue: only the queues you list. Deny all: none.",
          "default": "disabled",
          "oneOf": [
            { "const": "disabled", "title": "Disabled" },
            { "const": "allow_all", "title": "Allow all" },
            { "const": "by_queue", "title": "By queue" },
            { "const": "deny_all", "title": "Deny all" }
          ],
          "editableOn": ["create", "update"],
          "order": 20
        },
        "redrive_source_queues": {
          "type": "string",
          "title": "Source queue ARNs",
          "description": "Comma-separated ARNs of the queues allowed to use this queue as their dead-letter queue.",
          "editableOn": ["create", "update"],
          "order": 21
        },
        "dlq_enabled": {
          "type": "string",
          "title": "Dead-letter queue",
          "default": "disabled",
          "oneOf": [
            { "const": "disabled", "title": "Disabled" },
            { "const": "enabled", "title": "Enabled: send undeliverable messages to a dead-letter queue" }
          ],
          "editableOn": ["create", "update"],
          "order": 22
        },
        "dlq_arn": {
          "type": "string",
          "title": "Dead-letter queue ARN",
          "pattern": "^$|^arn:aws[a-z-]*:sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]{1,80}(\\.fifo)?$",
          "description": "ARN of the queue that receives undeliverable messages. It must be the same type (Standard or FIFO) as this queue and allow it in its redrive allow policy.",
          "editableOn": ["create", "update"],
          "order": 23
        },
        "dlq_max_receives": {
          "type": "integer",
          "title": "Maximum receives",
          "default": 10,
          "minimum": 1,
          "maximum": 1000,
          "description": "How many times a message can be received before it moves to the dead-letter queue.",
          "editableOn": ["create", "update"],
          "order": 24
        },
        "tags": {
          "type": "array",
          "title": "Tags",
          "items": {
            "type": "object",
            "properties": {
              "key": { "type": "string", "title": "Key" },
              "value": { "type": "string", "title": "Value" }
            },
            "required": ["key"]
          },
          "description": "Extra tags applied to the queue.",
          "editableOn": ["create", "update"],
          "order": 25
        },
        "queue_url": {
          "type": "string",
          "title": "Queue URL",
          "export": true,
          "readOnly": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "URL applications send to and receive from (auto-populated after creation)",
          "order": 26
        },
        "queue_arn": {
          "type": "string",
          "title": "Queue ARN",
          "export": true,
          "readOnly": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "ARN of the queue (auto-populated after creation)",
          "order": 27
        },
        "queue_name": {
          "type": "string",
          "title": "Queue Name",
          "export": false,
          "readOnly": true,
          "visibleOn": [],
          "editableOn": [],
          "description": "Internal queue name, fixed after creation"
        }
      }
    },
    "values": {}
  }
}
