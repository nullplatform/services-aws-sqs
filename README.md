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
│   └── requirements/aws/          # IAM role the agent assumes
├── publish/                       # publishes the service as a package (release workflow only)
├── deployment/                    # the queue, its policy and redrive policies
├── permissions/                   # link: IAM user, policy and access key
├── scripts/aws/                   # sqs_lib, context building, tofu execution, outputs
│   └── tests/aws/                 # BATS unit tests
├── utils/                         # assume role helpers
├── entrypoint/                    # action routing
├── workflows/aws/                 # one file per action
└── values.yaml                    # static config, not exposed in the UI
```

## Install in your organization

The service is published once as the package `np-aws-sqs` (specification "AWS SQS"), visible to every organization. You do not copy its specs: you install the package and use it read-only.

If you need to change the specification, the link, the actions or the workflows themselves, see [the global package, or your own fork](#two-ways-to-run-this-service-the-global-package-or-your-own-fork) below before installing anything.

Installing it touches the same three layers as registering a service yourself, and only the nullplatform layer changes:

| Layer | What | Module |
|---|---|---|
| infrastructure (AWS credentials) | The IAM role the service assumes, and the state bucket every SQS service shares | [`sqs/specs/requirements/aws`](./sqs/specs/requirements/aws) |
| nullplatform (nullplatform API key) | The installation of the package and the agent channel | tofu-modules' `service_package_installation` |
| bindings | The role under selector `sqs` in your IAM provider | your `aws-iam-configuration` provider |

Pick ONE release of this repository (the latest is on its [releases page](https://github.com/nullplatform/services-aws-sqs/releases)) and use its version in both places below: the IAM role is the one the worker of that same release expects.

```hcl
# ── infrastructure layer ─────────────────────────────────────────────
module "sqs_requirements" {
  source            = "git::https://github.com/nullplatform/services-aws-sqs.git//sqs/specs/requirements/aws?ref=vX.Y.Z"
  cluster_name      = "<nullplatform agent cluster>"
  state_bucket_name = "<existing S3 bucket for the tofu state>"
  # kms_key_arns: the keys your teams use; the default lets the role use any key.
}

# The agent role must be allowed to assume it: add it to the assume_role_arns
# of tofu-modules' infrastructure/aws/iam/agent.
#   assume_role_arns = [..., module.sqs_requirements.permissions_role_arn]

# ── nullplatform layer ───────────────────────────────────────────────
# The same module a catalog entry with `install_package` becomes. For a
# service the installation is the whole nullplatform side, channel included.
module "sqs" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_package_installation?ref=v9.16.0"

  nrn                  = var.nrn
  package_slug         = "np-aws-sqs"
  package_version      = "X.Y.Z" # the same release, without the v
  agent_tags_selectors = { cluster = "runtime" } # must match the agent's TAGS
}
# Keeping channels in a separate bindings layer instead? Use
# nullplatform/package_installation here and service_definition_agent_association
# there, with package_slug = "np-aws-sqs".

# ── bindings layer ───────────────────────────────────────────────────
# One aws-iam-configuration per NRN and dimensions: add the entry to the list
# your IAM provider already has.
#   { selector = "sqs", arn = module.sqs_requirements.permissions_role_arn }
```

**The state bucket.** Create one S3 bucket that every SQS service shares for its tofu state, enable versioning, and pass its name to the requirements module as `state_bucket_name`. The agent must receive the same name in the environment variable `SQS_S3_STATE_BUCKET`. The service never creates or deletes this bucket: if it is missing, every action fails with a clear error. Each service keeps its state under `services/sqs/<service id>/terraform.tfstate`, and each link under `services/sqs/<service id>/links/<link id>.tfstate`. Deleting a service removes that prefix and nothing else.

**Region.** The region comes from the account configuration (`aws.region`) or the account provider.

The service assumes the role it finds under selector `sqs` in the IAM provider closest to its NRN. To upgrade, move the release in both layers: `ref` of the requirements module and `package_version` of the installation. See tofu-modules' [`service_package_installation`](https://github.com/nullplatform/tofu-modules/tree/main/nullplatform/service_package_installation) for its inputs and outputs.

Prerequisites: an agent whose `TAGS` match the channel's `tags_selectors` and with `public.ecr.aws/nullplatform/*` in `worker.allowedRegistries`, and an AWS cloud provider exposing `account.region` at the NRN or above it.

### Already registered with `service_definition`?

Organizations that registered this service with `service_definition` have their own copy: specification "AWS SQS" (slug `aws-sqs`) and a channel filtered to that slug. The global package uses other names (`np-aws-sqs`), so both live side by side in one organization:

- In the nullplatform layer, add the installation (the module above, or a catalog entry with `install_package`) next to your `service_definition`. Its outputs have the same names, so the map your bindings layer reads keeps its shape, and its channel routes only the global slug: your existing channel keeps serving your copy.
- Keep your IAM role: both specifications assume the role under selector `sqs`, with the same permissions. The infrastructure layer does not change.
- Existing services stay on your copy (a service cannot move to another specification). Create new services from "AWS SQS", and remove your `service_definition` and its channel once no service uses them.

### Two ways to run this service: the global package, or your own fork

| | **Global package** (default) | **Your own fork** |
|---|---|---|
| Specs and code | Maintained by nullplatform in this repository | Maintained by you, in your fork |
| What you install | The package `np-aws-sqs`, read-only | A package you publish in your organization, or a registered copy |
| Updates | A new release: move the version | Only when you merge upstream into your fork |
| When | Always, unless you need changes to the specification, the links, the actions or the workflows | Substantial changes: new actions or links, another specification (attributes, validations), workflows that behave differently |

**Use the global package.** It is the only way to keep receiving fixes, features and security patches: each one arrives as a release of this repository and you take it by moving the installed version. The section above is that path; its two forms are the same module:

- From a catalog of `service_definition` entries (tofu-modules): the same entry with an `install_package = { slug = "np-aws-sqs", version = "X.Y.Z" }` block becomes a `service_package_installation`. For a service the installation is the whole nullplatform side, the agent channel included.
- From a root of your own: the module call in the section above, with the same inputs.

If something is missing or wrong, open an issue or a pull request here, so every organization gets it.

**Fork only to change what the service is.** A fork means you become the publisher of a different service: you build its worker image, publish its package in your organization and maintain its specs, code and installation. Step by step:

1. **Fork the repository and give the service its own names.** In [`sqs/publish/main.tf`](./sqs/publish/main.tf): `package_slug` (for example `acme-aws-sqs`) and `service_name` ("Acme SQS"); the specification takes the package slug. The slug must differ from `np-aws-sqs`, and from `aws-sqs` if you also run a copy: agent channels route by the specification slug, so two services with one slug share a worker. Link specifications keep their own slugs; give them yours with `link_slugs` only if they collide inside your organization.
2. **Publish into your organization, not every organization.** In the same file, add `visible_to = [var.publisher_nrn]` to the module call: the module publishes to every organization by default, which only the platform organization may, and your package is yours. Point `image_repository` (and `image_registry`, when it is not ECR Public) at your registry.
3. **Set the release workflow's secrets in your fork**: `ARTIFACT_NP_API_KEY` (a key of your organization, allowed to write artifacts, specifications and packages), `AWS_ROLE_ARN_ECR_PUSH`, `PACKAGE_STATE_AWS_ACCOUNT_ID` (with a role named `github-actions-<repository>-package-state` that may write the state bucket) or `AWS_ROLE_ARN_PACKAGE_STATE` (a role named otherwise), `PACKAGE_TFSTATE_BUCKET` and `PACKAGE_TFSTATE_REGION`, plus the `NP_ARTIFACT_NRN` variable. From then on, each release of your fork builds the image, registers it and publishes a revision of your package ([`release.yml`](./.github/workflows/release.yml)), versioned by its release tag.
4. **Install your package the same way as the global one**, with your slug in `install_package` and your own agent channel. The IAM role and its selector can stay `sqs` as long as the permissions in [`sqs/specs/requirements/aws`](./sqs/specs/requirements/aws) still fit what your fork does; if they do not, give your fork its own role and selector too.

**Your specs on our image: the shortcut, and why it is risky.** The worker image this repository publishes is a global artifact, so a package of your own may pin it (an artifact looked up by registry, repository and the digest of one of our releases, as the module behind [`sqs/publish`](./sqs/publish) does) and change only the specs. It saves you the build, and it is the main trade-off to understand before taking it: the code in that image reads the specification it was released with — the attributes the form collects, the actions and their parameters, the link specifications and what they export — so every change to your specs is a divergence the image does not know about, and the next release of ours assumes specs you no longer have. A service behaves as one thing because its specs and its code are released together; that coupling is the reason the global package carries both, and splitting them puts the breakage on your side, at runtime, with nothing in the platform to warn you. Take the shortcut only for changes the image cannot see, such as descriptions, defaults within the same shape, or visibility; anything the workflows read belongs with a forked image.

Without packages, the classic way still works: register your fork as a copy with `service_definition` pointing at your fork's repository and tag.

What a fork costs, before you take it:

- **Updates stop arriving.** Upstream fixes reach you only when you merge them into your fork yourself.
- **There is no way back for existing services.** A service cannot move to another specification: services created from your fork's specification stay on it.
- **You own the operations.** Images, releases, state of the publisher stack and the compatibility of your specs with the agent are yours to keep.

## How the package is published

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
| beta | PR (opened, push, reopened) | publish-test-image-oci: pushes `beta/<image>:test-<branch>-<short sha>` and registers it as a nullplatform artifact |
| release | push to `main` | release-please → build and push `vX.Y.Z` and `latest` to ECR Public → nullplatform artifact → GitHub release |
| auto-merge-release | after release | merges the release PR |
| dependabot | daily / weekly | base image and shared workflow bumps |

## Image tags

| Image | Moved by | Use it to |
|---|---|---|
| `agent-plugins/services/<name>:vX.Y.Z` | its release, once | pin an exact version |
| `agent-plugins/services/<name>:latest` | each release | follow the last released version |
| `beta/agent-plugins/services/<name>:test-<branch>-<short sha>` | each push to a pull request of this repository | deploy a change to a test scope before merging it |

Beta images live in a separate repository that the beta role can write and the production role cannot, so a beta can never overwrite a released image. Pull requests from this repository can assume the beta role (fork and bot pull requests are skipped), and the tag carries the commit SHA, so two pull requests never overwrite each other by accident. Nothing deletes beta tags: they are ephemeral by convention. Each beta is also registered as its own nullplatform oci_image artifact (the `beta/` repository, under `NP_ARTIFACT_NRN`), separate from the release artifact, so it can be deployed to a test scope from the platform.

## Publishing

After adding the **Public ECR** service to the application, set in this repository:

| Name | Kind | Value |
|---|---|---|
| `AWS_ROLE_ARN_ECR_PUSH` | secret | the publisher role ARN the Public ECR service returns |
| `NP_ARTIFACT_NRN` | variable | the NRN of the organization that owns the artifacts |
| `PACKAGE_STATE_AWS_ACCOUNT_ID`, `PACKAGE_TFSTATE_BUCKET`, `PACKAGE_TFSTATE_REGION` | organization secrets | where the publish stack keeps its state; the state role is `github-actions-<repository>-package-state` in that account, by convention |

`ARTIFACT_NP_API_KEY` comes from the organization. The release checks all three before building and fails with a clear error if one is missing. Beta images assume the role in the organization secret `AWS_BETA_ROLE_ARN` (no role is written in the workflow) and push to the image's `beta/` repository in ECR Public, which the dispatcher creates together with the production one. In this template repository neither workflow runs.
