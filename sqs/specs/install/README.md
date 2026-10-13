# Install: registering the AWS SQS service

This directory holds the reference OpenTofu/Terraform used to **install** AWS SQS on a nullplatform account. It registers the service specification, the link specification and the agent association (notification channel), so creating an SQS service starts routing its actions to an agent.

It is a guide to copy, not a module to apply from here: it declares no provider. Configure the `nullplatform` provider in the root module where you use it.

This is separate from `../requirements/aws`, which creates the IAM role the agent assumes in the AWS account that holds the queues. See the Installation section of the top-level [`README.md`](../../../README.md) for the full order.

## Layout

```
install/
├── README.md          (this file)
└── aws/               working example
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── terraform.tfvars.example
```

## Using the example

```bash
cp -r sqs/specs/install/aws /path/to/your/infra/aws-sqs
cd /path/to/your/infra/aws-sqs
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

tofu init
tofu apply
```

`repository_branch` must be a pinned ref (a release tag or a commit SHA): the specs are read from that ref of this repository.

`tags_selectors` must match the tags of the agents that should pick up SQS actions (the same selectors passed as `tags_selectors` to the `nullplatform/agent` tofu module).

Run this once per nullplatform namespace. It only registers the service with the platform and creates no AWS infrastructure: queues are created per service, at `create` time, by `deployment/` with the role from `requirements/aws`.
