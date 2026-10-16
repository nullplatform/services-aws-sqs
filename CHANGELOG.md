# Changelog

## [1.0.1](https://github.com/nullplatform/services-aws-sqs/compare/v1.0.0...v1.0.1) (2026-10-16)


### Bug Fixes

* **deps:** update dependency opentofu/opentofu to v1.13.1 ([#11](https://github.com/nullplatform/services-aws-sqs/issues/11)) ([7cde9f0](https://github.com/nullplatform/services-aws-sqs/commit/7cde9f0752566f1aadb56beb0efb8dccc5c6fb10))

## 1.0.0 (2026-10-13)


### Features

* **sqs:** add the AWS SQS service ([a0ecd75](https://github.com/nullplatform/services-aws-sqs/commit/a0ecd75040fcff47dd2f85ec87389a96f6d069e9))
* **sqs:** add the create, update, delete and read workflows ([cf9f381](https://github.com/nullplatform/services-aws-sqs/commit/cf9f38104b24844f6743966f1dbbdb502bf81f77))
* **sqs:** add the iam role the agent assumes and validate the modules in ci ([2a1b28b](https://github.com/nullplatform/services-aws-sqs/commit/2a1b28b3e9d0c01c0a42ef81a74b84006fa3fd0f))
* **sqs:** add the input conversion and validation library ([b66ce4b](https://github.com/nullplatform/services-aws-sqs/commit/b66ce4b98b384d5904c43516b6ca3f96cbd0de1a))
* **sqs:** add the link workflows with a per-link iam user and queue policy ([7cdabbe](https://github.com/nullplatform/services-aws-sqs/commit/7cdabbe995f31820ae6a942e986fb00187710ee0))
* **sqs:** add the modules that register the service and its agent channel ([be1cd2e](https://github.com/nullplatform/services-aws-sqs/commit/be1cd2e626fef22998a12a110ca9c820e9adb7a8))
* **sqs:** add the opentofu module that creates the queue and its policies ([241a8e0](https://github.com/nullplatform/services-aws-sqs/commit/241a8e0abdedee56619e7c974ba06c3ebf9995d6))
* **sqs:** add the service and link specs with the queue form ([189cd56](https://github.com/nullplatform/services-aws-sqs/commit/189cd560bf0aa85ef9dcb9772ba83baa083dc7a7))
* **sqs:** build the queue context and tofu variables from the service attributes ([8b146e2](https://github.com/nullplatform/services-aws-sqs/commit/8b146e243088ba440930e26834a6ba39e1d355ac))
* **sqs:** reuse the assume-role, tofu and state cleanup scripts from valkey ([98dc7b9](https://github.com/nullplatform/services-aws-sqs/commit/98dc7b91b064ab43181d1c5b44b331729f7640df))
* **sqs:** write the queue url, arn and name back to the service ([241f5a5](https://github.com/nullplatform/services-aws-sqs/commit/241f5a5ecea30e5c68e4ff04276969912c5029cc))


### Bug Fixes

* **sqs:** fail early with a clear message when the queue name is taken ([c2b8a52](https://github.com/nullplatform/services-aws-sqs/commit/c2b8a52f7d840309d3095d7b1a9f936a14dc8a1a))
* **sqs:** let delete skip form validation and list the state bucket without a prefix ([4c92740](https://github.com/nullplatform/services-aws-sqs/commit/4c9274076d8697a2e492f81b9c2d2381c356d9f6))

## Changelog
