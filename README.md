# services-aws-sqs

Nullplatform service that provisions **AWS SQS queues** (Standard or FIFO) and connects them to applications.

## What it does

Creates one queue per service instance, always encrypted, and hands each linked application its own IAM user and access key.

| Capability | Notes |
| :---- | :---- |
| Queue type | Standard or FIFO, chosen at creation and fixed afterwards |
| Settings | Visibility timeout, message retention, delivery delay, maximum message size, receive wait time, each editable after creation |
| Encryption | Always on: SSE-SQS by default, or SSE-KMS with the ARN of your key or alias and a data key reuse period |
| Access policy | Only the queue owner, or the accounts, users and roles you list, separately for sending and receiving |
| Dead letters | Optional dead-letter queue with a maximum receives, and an optional redrive allow policy (all / by queue / deny all) |
| Tags | Your tags plus the platform's; the agent role can only touch resources it created |

## Links

| Link | What it does |
| :---- | :---- |
| `create-aws-sqs-link` | Creates an IAM user with send, receive, delete, change-visibility and attribute access to this queue (plus `kms:GenerateDataKey` and `kms:Decrypt` on the key of an SSE-KMS queue), and exports its access key. |

## Layout

```
sqs/
├── specs/
│   ├── service-spec.json.tpl      # the form the developer sees
│   ├── links/connect.json.tpl
│   ├── requirements/aws/          # IAM role the agent assumes
│   └── install/                   # registers the service and routes its actions to an agent
├── deployment/                    # the queue, its policy and redrive policies
├── permissions/                   # link: IAM user, policy and access key
├── scripts/aws/                   # sqs_lib, context building, tofu execution, outputs
│   └── tests/aws/                 # BATS unit tests
├── utils/                         # assume role helpers
├── entrypoint/                    # action routing
├── workflows/                     # one file per action
└── values.yaml                    # static config, not exposed in the UI
```

## Installation

**1. Create the permissions role.** Apply `sqs/specs/requirements/aws` in the target AWS account:

```hcl
module "sqs_requirements" {
  source            = "git::https://github.com/nullplatform/services-aws-sqs.git//sqs/specs/requirements/aws?ref=main"
  cluster_name      = "<nullplatform agent cluster>"
  state_bucket_name = "<existing S3 bucket for the tofu state>"
}
```

To apply it as a root module instead, copy `terraform.tfvars.example` to `terraform.tfvars` and fill it in. Set `kms_key_arns` to the keys your teams use; the default lets the role use any key.

**2. Publish the role.** Register `permissions_role_arn` in the nullplatform AWS IAM provider under the selector **`sqs`**, and allow the agent role to assume it.

**3. Create the state bucket.** Create one S3 bucket that every SQS service shares for its tofu state, enable versioning, and pass its name to the requirements module as `state_bucket_name`. The agent must receive the same name in the environment variable `SQS_S3_STATE_BUCKET`. The service never creates or deletes this bucket: if it is missing, every action fails with a clear error.

Each service keeps its state under `services/sqs/<service id>/terraform.tfstate`, and each link under `services/sqs/<service id>/links/<link id>.tfstate`. Deleting a service removes that prefix and nothing else.

**4. Region.** The region comes from the account configuration (`aws.region`) or the account provider.

**5. Register the service.** Apply `sqs/specs/install`. It registers the service and link specifications and the notification channel that routes their actions to the agents matching `agent_tags_selectors`:

```hcl
module "sqs_install" {
  source               = "git::https://github.com/nullplatform/services-aws-sqs.git//sqs/specs/install?ref=<tag>"
  nrn                  = "organization=<id>:account=<id>"
  api_key              = "<nullplatform api key>"
  repository_branch    = "<tag>"
  agent_tags_selectors = { service = "aws-sqs" }
}
```

`repository_branch` must be a tag or commit SHA, never a moving branch. To test local changes, set `git_provider = "local"`, `local_specs_path` to this repository's `sqs/` directory and `base_clone_path = "~/.np"`; the specs are then read from disk. To apply it as a root module, copy `terraform.tfvars.example` to `terraform.tfvars` first; `*.tfvars` are git-ignored.

## How it works

Before any AWS call, each workflow assumes the permissions role published in the IAM provider under the selector `sqs`, and every later step runs on the temporary credentials it returns. When the provider publishes no role for that selector, the agent keeps its own credentials, which is what makes local testing work.

`build_context` turns the form into a `terraform.tfvars.json`. Every "value + unit" pair is converted to seconds, and every range is checked there with a message that names the field, because the form schema cannot validate a value against a unit.

The queue is named `np-<name>`, or `np-<name>.fifo` for FIFO, and the name is saved in the service attributes (`queue_name`) the first time. Renaming the service or editing the form never renames or recreates the queue. The `np-` prefix is what scopes the permissions role to queues created by nullplatform. SQS names are unique per account and region, so a second queue with the same name fails with `QueueAlreadyExists`.

Each link user is named `np-<link slug>-<first 5 characters of the link id>-user`. Its access key is generated by Terraform, stored only in the link's state and attributes, and delivered to the application as a secret environment variable.

## Connecting

nullplatform creates these variables as parameters of the linked application when the link is created, and removes them when it is deleted. Each name is the service name in upper case, with hyphens turned into underscores, followed by the attribute. For a service named `orders-queue`:

| Variable | From | |
| :---- | :---- | :---- |
| `ORDERS_QUEUE_QUEUE_URL` | service | Queue URL |
| `ORDERS_QUEUE_QUEUE_ARN` | service | Queue ARN |
| `ORDERS_QUEUE_AWS_REGION` | link | Region of the queue |
| `ORDERS_QUEUE_ACCESS_KEY_ID` | link | Access key of the link's IAM user |
| `ORDERS_QUEUE_SECRET_ACCESS_KEY` | link | secret |

Map them to the standard names your SDK reads (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`) and send to the queue URL.

An SSE-KMS queue also needs the key policy of your key to allow the link user (`kms:GenerateDataKey`, `kms:Decrypt`).

A link's KMS permissions are computed when the link is created or updated, not when the queue is. After you switch a queue to SSE-KMS or change its `kms_key_arn`, run a link update on each link of that queue (or recreate it), otherwise its application gets `AccessDenied` from KMS until you do.

## Local testing

Set `aws_profile` in `values.yaml`, run `aws sso login --profile <name>`, and start the agent with `np package run` (below). With no IAM provider configured, the service runs on that profile's credentials.

Unit tests run with [bats-core](https://github.com/bats-core/bats-core):

```bash
bats sqs/scripts/tests/aws/ sqs/utils/tests/
```

## Run locally as a package

`np package run` runs this service on your machine the way production does: a
local controlplane-agent that registers with the platform, spawns the worker
image built from this repo, and hands it every action routed to it. No cluster,
no publish. The two tasks in `mise.toml` are the whole contract with the CLI:

| Command | Runs | Does |
|---|---|---|
| `np package build --image` | `mise run build:image` | Builds `sqs-worker:dev` |
| `np package run` | `mise run run` | Builds the image, then starts the local agent |

Prerequisites: **Docker** with host networking (Linux as is; on Docker Desktop
enable *host networking*), **[mise](https://mise.jdx.dev)** (`mise trust` once
here), an **`NP_API_KEY`** for the agent to register with, and `np` from the
**alpha** channel, which carries `np package run`:

```bash
curl -fsSL https://cli.nullplatform.com/install.sh | VERSION=alpha sh   # ~/.local/bin/np
np package run --help                                                   # must list --no-forward-env
```

```bash
export NP_API_KEY=...
eval "$(aws configure export-credentials --format env)"   # cloud credentials as variables
np package run --log-level DEBUG                          # Ctrl+C to stop
```

The agent is tagged `package:sqs` and `local:<your user>`. It receives an
action only when the service's notification channel selects those tags, so
point a channel at `local:<your user>` to route work to your machine.

> **Tags decide who gets the work.** Never start a local agent with tags a
> production channel selects: it would receive production actions.

`np package run` forwards your shell's environment to the agent container,
minus what describes your machine (`PATH`, `HOME`, `DOCKER_*`, `KUBECONFIG`,
`AWS_PROFILE` and the other file-pointing AWS variables), and the `run` task
passes the same variables to the worker through an `NP_WORKER_RULES` entry.
Every secret in your shell crosses too, and is readable with `docker inspect`;
pass `--no-forward-env` to forward nothing.

| Variable | Default | Purpose |
|---|---|---|
| `NP_API_KEY` | required | The key the agent registers with (`--api-key` also sets it) |
| `NP_LOG_LEVEL` | `INFO` | Agent log level (`--log-level` also sets it) |
| `NP_PACKAGE_SLUG` | `sqs` | The slug in the `package:<slug>` tag, when published under another slug |
| `NP_LOCAL_USER` | `$USER` | The value of the `local:<user>` tag |
| `NP_AGENT_IMAGE` | `controlplane-agent:latest` | The agent image; needs worker rules (0.11.1+) |

The local run never changes what the platform runs. To ship the change, merge
it: the release publishes the image and registers the artifact.

## CI

| Workflow | When | What |
|---|---|---|
| branch-validation | PR | branch named `feat/…`, `fix/…`, `chore/…` |
| conventional-commit | PR | commit messages (release-please reads them) |
| shellcheck | PR | every bash script |
| tests | PR | BATS unit tests, `do_tofu` version pin, and `tofu validate` of the four modules |
| trivy | PR | IaC misconfiguration and image scan, to the Security tab |
| beta | push to `beta/**` | builds the image, pushes `beta/<image>:test-beta-<name>-<short sha>` and registers it as a nullplatform artifact |
| release | push to `main` | release-please → build and push `vX.Y.Z` and `latest` to ECR Public → nullplatform artifact → GitHub release |
| auto-merge-release | after release | merges the release PR |
| dependabot | daily / weekly | base image and shared workflow bumps |

## Image tags

| Image | Moved by | Use it to |
|---|---|---|
| `agent-plugins/services/<name>:vX.Y.Z` | its release, once | pin an exact version |
| `agent-plugins/services/<name>:latest` | each release | follow the last released version |
| `beta/agent-plugins/services/<name>:test-beta-<name>-<short sha>` | each push to a `beta/<name>` branch | try a change on a test scope before merging it |

Beta images live in a separate repository that the beta role can write and the production role cannot, so a beta can never overwrite a released image. Publish one with `git push origin HEAD:beta/<name>`; the short SHA in the tag keeps two branches from overwriting each other.

## Publishing

After adding the **Public ECR** service to the application, set in this repository:

| Name | Kind | Value |
|---|---|---|
| `AWS_ROLE_ARN_ECR_PUSH` | secret | the publisher role ARN the Public ECR service returns |
| `NP_ARTIFACT_NRN` | variable | the NRN of the organization that owns the artifacts |

`ARTIFACT_NP_API_KEY` comes from the organization. The release checks all three before building and fails with a clear error if one is missing. Beta images assume the role in the organization secret `AWS_BETA_ROLE_ARN` (no role is written in the workflow) and need the service's `beta/` repository in ECR Public: without it the push fails with `repository does not exist`. In this template repository neither workflow runs.
