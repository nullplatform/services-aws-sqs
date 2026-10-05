{
  "name": "AWS SQS Link",
  "slug": "create-aws-sqs-link",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "use_default_naming": false,
  "use_managed_actions": false,
  "selectors": {
    "category": "any",
    "imported": false,
    "provider": "any",
    "sub_category": "any"
  },
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": [
        "access_key_id",
        "secret_access_key"
      ],
      "properties": {
        "access_key_id": {
          "type": "string",
          "title": "Access Key ID",
          "export": true,
          "readOnly": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Access key of the IAM user created for this link (auto-populated after link creation)",
          "order": 1
        },
        "secret_access_key": {
          "type": "string",
          "title": "Secret Access Key",
          "export": {
            "type": "environment_variable",
            "secret": true
          },
          "readOnly": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Secret of the link's access key (auto-populated, delivered as secret env var)",
          "order": 2
        },
        "aws_region": {
          "type": "string",
          "title": "AWS Region",
          "export": true,
          "readOnly": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Region of the queue (auto-populated after link creation)",
          "order": 3
        }
      }
    },
    "values": {}
  }
}
