# syntax=docker/dockerfile:1
# Worker image: the bridge runs the entrypoint on every action. Add the tools your steps need.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:2.0.3

# The steps call the AWS CLI (state bucket checks, state cleanup) and OpenTofu; jq and the np CLI ship with the bridge.
RUN apk add --no-cache aws-cli

ARG TOFU_VERSION=1.13.1
ARG TARGETARCH
RUN curl -fsSL "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${TARGETARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin tofu \
    && tofu version

# --chown: np chmods the action script in place, so the tree must belong to the runtime uid.
COPY --chown=10001:10001 . /app/pkg
ENV NP_PACKAGE_NAME=sqs \
    NP_SERVICE_PATH=/app/pkg/sqs \
    NP_SCOPE_ENTRYPOINT=/app/pkg/sqs/entrypoint/entrypoint

# Numeric so runAsNonRoot admission can verify it; worker-bridge 2.0.0+ ships this user and a writable HOME.
USER 10001:10001
