# AWS SQS service — design

Date: 2026-10-05
Status: approved in conversation, pending written-spec review

## Goal

A nullplatform service that provisions **AWS SQS queues** (Standard or FIFO) and connects them to applications, built the way `services-valkey` is built. Developers configure the queue from the nullplatform UI; each linked application receives its own IAM user and credentials.

The repository starts from the `services-*` template already in this repo (`my-service/`, worker-bridge `Dockerfile`, `mise.toml`, CI) and takes the execution logic from `services-valkey`: assume-role, context building, OpenTofu execution, per-service and per-link state, BATS tests and the IAM requirements module.

## Out of scope

- Content-based deduplication, FIFO throughput limits and other queue attributes not listed below.
- Per-link access level (send / receive / both). Links grant full access, like valkey.
- Listing KMS keys from AWS in the UI (nullplatform specs cannot do it).
- The SNS service. It is a separate repo with its own spec; the SQS queue policy needed for SNS subscriptions is decided there.

## Layout

```
sqs/
├── entrypoint/            entrypoint, service, link (from the template)
├── workflows/             create, update, delete, read, link, link-update, unlink
├── scripts/aws/           build_context, build_permissions_context, do_tofu,
│   │                      write_service_outputs, write_link_outputs, delete_tfstate_objects
│   └── tests/aws/         BATS unit tests
├── utils/                 assume_role, assume_role_step, assume_role_lib (+ tests)
├── deployment/            OpenTofu: queue, queue policy, redrive policies
├── permissions/           OpenTofu: per-link IAM user, policy, access key
├── specs/
│   ├── service-spec.json.tpl
│   ├── links/connect.json.tpl
│   └── requirements/aws/  IAM role the agent assumes
└── values.yaml
nullplatform/              service_definition registration (same as valkey)
nullplatform-bindings/     agent association (same as valkey)
```

`my-service` is renamed to `sqs` everywhere, as the template README describes. Display name `AWS SQS`; service slug `aws-sqs`; link slug `create-aws-sqs-link`.

## Service attributes

All input attributes are editable on create. `queue_type` and `name` are not editable afterwards; every other input is editable on update. Fields are grouped with a JSON Forms `uiSchema`; the configuration fields sit in a **Configuration** section.

| Attribute | Type | Default | Constraint |
|---|---|---|---|
| `queue_type` | enum `Standard` / `FIFO` | Standard | create only |
| `name` | string | — | 1–72 chars, `[A-Za-z0-9_-]`, create only |
| `visibility_timeout_value` + `_unit` (seconds / minutes / hours) | number + enum | 30 seconds | 0 s – 12 h |
| `message_retention_value` + `_unit` (seconds / minutes / hours / days) | number + enum | 4 days | 1 min – 14 days |
| `delivery_delay_value` + `_unit` (seconds / minutes) | number + enum | 0 seconds | 0 s – 15 min |
| `max_message_size_kib` | number | 1024 | 1 – 1024 KiB |
| `receive_wait_time_seconds` | number | 0 | 0 – 20 s |
| `encryption` | read-only text | `Enabled` | always on |
| `encryption_key_type` | enum `SSE-SQS` / `SSE-KMS` | SSE-SQS | |
| `kms_key_arn` | string | — | shown only for SSE-KMS; key ARN or alias ARN |
| `data_key_reuse_value` + `_unit` (minutes / hours) | number + enum | 5 minutes | 1 min – 24 h; shown only for SSE-KMS |
| `send_access` | enum `owner` / `principals` | owner | |
| `send_principals` | string, comma-separated | — | shown only for `principals`; account IDs or IAM user/role ARNs |
| `receive_access`, `receive_principals` | same as send | owner | |
| `redrive_allow` | enum `Disabled` / `Allow all` / `By queue` / `Deny all` | Disabled | |
| `redrive_source_queues` | string, comma-separated ARNs | — | shown only for `By queue` |
| `dlq_enabled` | enum `Disabled` / `Enabled` | Disabled | |
| `dlq_arn` | string | — | shown only when enabled |
| `dlq_max_receives` | number | 10 | 1 – 1000; shown only when enabled |
| `tags` | list of key/value | — | |

Outputs (read-only, populated after create): `queue_url` (exported), `queue_arn` (exported), `queue_name` (internal, frozen — see Naming).

Environment-derived inputs (`aws_region`, hidden) follow valkey: from the account configuration `aws.region`, else from the account provider.

## Conditional fields and fallbacks

Conditional visibility uses JSON Forms `rule: { effect: SHOW, condition }` in the `uiSchema`. No existing `services-*` repo uses rules, so this is verified when the service is first registered. If the nullplatform renderer ignores rules, the fallback is to show every field and have `build_context` ignore the ones that do not apply. The same verification covers the `tags` list; its fallback is a single `key=value,key2=value2` string.

The schema itself carries `minimum`/`maximum`, `enum`, `default` and `pattern`. Limits that depend on the unit cannot be expressed there, so `build_context` converts every value to seconds (or bytes) and fails with a clear message when the converted value is outside the AWS range.

## Naming and state

- AWS queue name: `np-<name>`, plus `.fifo` for FIFO. At most 80 characters, hence the 72-character limit on `name`. Computed once and written to `queue_name`; later runs reuse the attribute, so renaming the service never renames the queue. The `np-` prefix is what scopes the agent's IAM role to nullplatform queues.
- SQS names are unique per account and region. A collision surfaces AWS's `QueueAlreadyExists`.
- State bucket: one shared S3 bucket, read from `SQS_S3_STATE_BUCKET` on the agent; never created or deleted by the service, and every action fails clearly when it is missing.
- Keys: `services/sqs/<service-id>/terraform.tfstate` and `services/sqs/<service-id>/links/<link-id>.tfstate`. Deleting a service removes that prefix only.
- Every resource is tagged `managed-by=nullplatform` plus the user's tags; the agent role can only touch resources it created.

## `deployment/` (OpenTofu)

- `aws_sqs_queue`: `fifo_queue`, `visibility_timeout_seconds`, `message_retention_seconds`, `delay_seconds`, `max_message_size` (bytes = KiB × 1024), `receive_wait_time_seconds`. With SSE-SQS, `sqs_managed_sse_enabled = true`; with SSE-KMS, `kms_master_key_id` and `kms_data_key_reuse_period_seconds`.
- `aws_sqs_queue_policy`: built from `send_access` / `receive_access`. `owner` allows only the queue's account; `principals` additionally allows the listed principals (bare account IDs become `arn:aws:iam::<id>:root`). Send covers `sqs:SendMessage`; receive covers `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:ChangeMessageVisibility`, `sqs:GetQueueAttributes`.
- `aws_sqs_queue_redrive_policy` when `dlq_enabled`: `deadLetterTargetArn` and `maxReceiveCount`.
- `aws_sqs_queue_redrive_allow_policy` when `redrive_allow` is not Disabled: `allowAll`, `byQueue` with `sourceQueueArns`, or `denyAll`.
- Variable validations repeat the checks that fit in OpenTofu: KMS ARN pattern (`^arn:aws[a-z-]*:kms:<region>:<12 digits>:(key|alias)/...`), principal format, ARN format, and that a FIFO queue's DLQ is FIFO.

## `permissions/` (link)

Per link, in its own state:

- `aws_iam_user` named `np-<link slug>-<first 5 chars of link id>-user` (same derivation as valkey), tagged `managed-by=nullplatform` and `link-id`.
- `aws_iam_user_policy` on that user for the queue: send, receive, delete, change visibility, get attributes, get URL. With SSE-KMS it also allows `kms:GenerateDataKey` and `kms:Decrypt` on the configured key. The key's own policy must allow the user; that is the key owner's responsibility and is documented in the README.
- `aws_iam_access_key`.

`write_link_outputs` patches the link with `access_key_id`, `secret_access_key` (secret) and `aws_region`. `queue_url` and `queue_arn` are exported from the service attributes. nullplatform names each exported variable `<LINK SLUG>_<ATTRIBUTE>` in upper case with hyphens removed (for example `ORDERSAPI_ACCESS_KEY_ID`); it fails rather than writing credentials it cannot read, as valkey does. Applications receive them as environment variables, the secret ones as secrets.

## Workflows

Same step order as valkey for every action: assume role → build context → tofu → write outputs. `delete` also runs `delete_tfstate_objects`. `assume_role` uses the IAM provider selector `sqs`; with no role published, the agent's own credentials are used, which keeps local testing working. `link` and `unlink` add `build_permissions_context`.

## IAM requirements module

`specs/requirements/aws` creates the role the agent assumes: SQS actions on `arn:aws:sqs:*:<account>:np-*`, `iam` user/policy/access-key management for `np-*-user`, state-bucket access scoped to `services/sqs/*`, and KMS describe/grant permissions needed to create a queue with a customer key. It takes `cluster_name` and `state_bucket_name`, as valkey does.

## Testing

- BATS unit tests for the scripts, following `services-valkey` (`build_context`, `build_permissions_context`, `do_tofu`, `write_service_outputs`, `write_link_outputs`, `delete_tfstate_objects`, assume-role helpers). `build_context` tests cover unit conversion, range errors and name freezing.
- `tofu validate` on `deployment/` and `permissions/`.
- Manual end to end, per `np-service-craft`: register with `git_provider = "local"`, run a local agent, create a Standard and a FIFO queue, a KMS queue, a DLQ pair and a link, and send/receive with the link's credentials. This is also where the rule and `tags` rendering are verified.

## Documentation

The README follows the template and valkey: what it does, links, layout, installation (requirements role, publish the role, state bucket, register the service), how it works, connecting, local testing.
