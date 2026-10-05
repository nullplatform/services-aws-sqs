# AWS SQS Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the nullplatform service that provisions AWS SQS queues (Standard or FIFO) and gives each linked application its own IAM user, following `services-valkey`.

**Architecture:** The repo starts from the `services-*` template already here (`my-service/` renamed to `sqs/`, worker-bridge image, `np package run`). Execution logic is lifted from `services-valkey`: assume-role, `build_context` → OpenTofu → write outputs, per-service and per-link state in one shared S3 bucket. A pure bash library (`sqs_lib`) converts units and validates inputs before OpenTofu runs; two OpenTofu modules (`deployment/` for the queue, `permissions/` for the link) do the AWS work.

**Tech Stack:** bash, jq, OpenTofu 1.12.6 + AWS provider `~> 6.0`, BATS (unit tests), nullplatform `np` CLI workflows, JSON Forms `uiSchema` for the form.

**Spec:** `docs/superpowers/specs/2026-10-05-aws-sqs-service-design.md`

## Global Constraints

- Branch `feat/aws-sqs-service`; commits are Conventional Commits with scope `sqs`, lowercase subject (`feat(sqs): …`, `test(sqs): …`, `ci(sqs): …`, `docs(sqs): …`, `chore(sqs): …`), ending with the `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` line.
- Service directory is `sqs/`; service slug `aws-sqs`, display name `AWS SQS`; link slug `create-aws-sqs-link`; package slug `sqs`.
- AWS queue name `np-<name>`, plus `.fifo` for FIFO, at most 80 characters, so `name` is 1–72 characters of `[A-Za-z0-9_-]`. Computed once, frozen in the `queue_name` attribute.
- Ranges (seconds unless noted): visibility timeout 0–43200; message retention 60–1209600; delivery delay 0–900; max message size 1–1024 KiB (sent to AWS as KiB × 1024 bytes); receive wait time 0–20; data key reuse 60–86400; dead-letter max receives 1–1000.
- Defaults: visibility 30 seconds; retention 4 days; delay 0 seconds; size 1024 KiB; wait 0; data key reuse 5 minutes; encryption SSE-SQS; send/receive access `owner`; redrive allow `disabled`; dead-letter queue `disabled` with max receives 10.
- Allowed units: visibility `seconds|minutes|hours`; retention `seconds|minutes|hours|days`; delay `seconds|minutes`; data key reuse `minutes|hours`.
- State bucket comes from the agent variable `SQS_S3_STATE_BUCKET` and is never created or deleted. Keys: `services/sqs/<service-id>/terraform.tfstate` and `services/sqs/<service-id>/links/<link-id>.tfstate`.
- Assume-role selector in the IAM provider: `sqs` (override variable `SQS_ASSUME_ROLE_SELECTOR`). With no role published the agent's own credentials are used.
- OpenTofu 1.12.6 (same pin as `do_tofu`), AWS provider `~> 6.0`, random provider not needed.
- Every AWS resource is tagged `managed-by=nullplatform`; link users also `link-id`. The agent role is scoped to the `np-` prefix.
- Enum values stored in attributes are lowercase: `standard|fifo`, `sse-sqs|sse-kms`, `owner|principals`, `disabled|allow_all|by_queue|deny_all`, `disabled|enabled`.
- All bash scripts must pass `shellcheck` (CI runs it); BATS files use tab indentation like valkey's.
- Local machine has `bats`, `tofu` and `jq`; it has **no** `docker` and **no** `shellcheck`. The image build and shellcheck are verified by CI on the PR.

## Review Focus

1. A whole-number field that is blank, decimal (`1.5`), negative, in exponent form (`1e3`), zero-padded (`08`) or 10+ digits must fail with a clear message (or normalize, for `08`), never an arithmetic error — pinned in Task 3.
2. A 72-character `name` on a FIFO queue lands exactly on AWS's 80-character limit, and 73 is rejected — Task 3.
3. A principals list with spaces, empty entries or a trailing comma is normalized; one with only separators is rejected; an entry that is not an account ID or IAM ARN is rejected — Tasks 3 and 4.
4. An update that sends a different `queue_type` or `name` after creation must not rename or replace the queue: the frozen `queue_name` wins and FIFO is derived from its suffix — Task 4.
5. `kms_key_arn` as an alias ARN: the link's IAM policy needs the resolved key ARN, so `permissions/` resolves it with a data source — Task 8 (`tofu validate`) and Task 13 (real run).
6. A link arriving when the service has no `queue_name`/`queue_arn` yet fails with a message that says the queue must exist first — Tasks 4 and 8.

---

### Task 1: Rename the template to `sqs` and give the image its tools

**Files:**
- Rename: `my-service/` → `sqs/`
- Modify: every file that mentions `my-service` outside `docs/` (Dockerfile, `mise.toml`, `.github/workflows/*`, README)
- Modify: `Dockerfile`
- Modify: `docs/superpowers/specs/2026-10-05-aws-sqs-service-design.md`

**Interfaces:**
- Produces: the `sqs/` directory every later task writes into; image tag `sqs-worker:dev`; package slug `sqs`.

- [ ] **Step 1: Rename the directory and the slug**

```bash
cd /Users/patrick.munoz/nullplatform/repositories/services-aws-sqs
git mv my-service sqs
grep -rl my-service . --exclude-dir=.git --exclude-dir=docs | xargs perl -pi -e 's/my-service/sqs/g'
```

- [ ] **Step 2: Verify nothing was missed**

Run: `grep -rn "my-service" . --exclude-dir=.git --exclude-dir=docs`
Expected: no output.

Run: `grep -n "sqs" Dockerfile mise.toml .github/workflows/release.yml .github/workflows/beta.yml`
Expected: `NP_PACKAGE_NAME=sqs`, `NP_SERVICE_PATH=/app/pkg/sqs`, `sqs-worker:dev`, `agent-plugins/services/sqs` appear.

- [ ] **Step 3: Give the worker image the AWS CLI and OpenTofu**

Replace the whole `Dockerfile` with:

```dockerfile
# syntax=docker/dockerfile:1
# Worker image: the bridge runs the entrypoint on every action. Add the tools your steps need.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:2.0.1

# The steps call the AWS CLI (state bucket checks, state cleanup) and OpenTofu; jq and the np CLI ship with the bridge.
RUN apk add --no-cache aws-cli

ARG TOFU_VERSION=1.12.6
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
```

`TOFU_VERSION` must stay equal to the pin inside `sqs/scripts/aws/do_tofu` (Task 2). If the CI image build fails with `apk: not found`, the base is no longer Alpine: check it with `docker run --rm --entrypoint sh public.ecr.aws/nullplatform/scopes/worker-bridge:2.0.1 -c 'cat /etc/os-release'` and swap the install line.

- [ ] **Step 4: Correct two statements in the spec**

In `docs/superpowers/specs/2026-10-05-aws-sqs-service-design.md`:

1. In the Layout block replace the line
   `├── workflows/aws/         create, update, delete, read, link, link-update, unlink`
   with
   `├── workflows/             create, update, delete, read, link, link-update, unlink`
   (the template's `entrypoint/service` runs `workflows/<action>.yaml`, so workflows stay flat; scripts keep `scripts/aws/`).
2. In the `permissions/` section replace
   `` `write_link_outputs` patches the link with `access_key_id`, `secret_access_key` (secret), `queue_url`, `queue_arn` and `aws_region`; ``
   with
   `` `write_link_outputs` patches the link with `access_key_id`, `secret_access_key` (secret) and `aws_region`. `queue_url` and `queue_arn` are exported from the service attributes. nullplatform names each exported variable `<LINK SLUG>_<ATTRIBUTE>` in upper case with hyphens removed (for example `ORDERSAPI_ACCESS_KEY_ID`); ``

- [ ] **Step 5: Keep the docs and CI scripts out of the image**

Append to `.dockerignore`:

```
docs
tests
nullplatform
nullplatform-bindings
```

- [ ] **Step 6: Check the shell scripts still parse and commit**

Run: `bash -n sqs/entrypoint/entrypoint sqs/entrypoint/service sqs/entrypoint/link && echo OK`
Expected: `OK`

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore(sqs): rename the template to sqs and add aws cli and opentofu to the image

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Reuse valkey's shared utilities and their tests

**Files:**
- Create: `sqs/utils/assume_role`, `sqs/utils/assume_role_lib`, `sqs/utils/assume_role_step`
- Create: `sqs/utils/tests/helpers.bash`, `assume_role.bats`, `assume_role_lib.bats`, `assume_role_step.bats`
- Create: `sqs/scripts/aws/do_tofu`, `sqs/scripts/aws/delete_tfstate_objects`
- Create: `sqs/scripts/tests/aws/helpers.bash`, `do_tofu.bats`, `delete_tfstate_objects.bats`
- Create: `tests/do_tofu_version.sh`, `.github/workflows/tests.yml`

**Interfaces:**
- Produces (used by every later task): `sqs/scripts/tests/aws/helpers.bash` with `setup_mocks`, `service_context [attrs_json] [params_json]`, `link_context …`, `full_params`, `run_script <name>`, `captured <VAR>`, `tfvar <jq path>`, `assert_equal`, `assert_contains`, `assert_not_contains`. `run_script` sources `$SCRIPTS_DIR/<name>`, then exposes `$status`, `$captured_stdout`, `$captured_stderr` and the exported variables through `captured`. Mocked binaries `aws`, `np`, `tofu` log to `$MOCK_LOG`.
- Produces: `do_tofu` (reads `TOFU_ACTION`, `OUTPUT_DIR`, `TOFU_MODULE_DIR`, `TOFU_INIT_VARIABLES`, `TOFU_VARIABLES`), `delete_tfstate_objects` (reads `REGION`, `TFSTATE_BUCKET`, `TFSTATE_KEY_PREFIX`), `assume_role_step`.

- [ ] **Step 1: Copy the utilities with the valkey names replaced**

```bash
cd /Users/patrick.munoz/nullplatform/repositories/services-aws-sqs
V=/Users/patrick.munoz/nullplatform/repositories/services-valkey
RENAME='s/VALKEY_/SQS_/g; s/valkey/sqs/g'
mkdir -p sqs/utils/tests sqs/scripts/aws sqs/scripts/tests/aws tests

for f in assume_role assume_role_lib assume_role_step; do
  sed "$RENAME" "$V/valkey/utils/$f" > "sqs/utils/$f"
done
for f in helpers.bash assume_role.bats assume_role_lib.bats assume_role_step.bats; do
  sed "$RENAME" "$V/valkey/utils/tests/$f" > "sqs/utils/tests/$f"
done
sed "$RENAME" "$V/valkey/scripts/aws/do_tofu" > sqs/scripts/aws/do_tofu
cp "$V/valkey/scripts/aws/delete_tfstate_objects" sqs/scripts/aws/delete_tfstate_objects
for f in do_tofu.bats delete_tfstate_objects.bats; do
  sed "$RENAME" "$V/valkey/scripts/tests/aws/$f" > "sqs/scripts/tests/aws/$f"
done
cp "$V/tests/do_tofu_version.sh" tests/do_tofu_version.sh
chmod +x sqs/utils/assume_role sqs/utils/assume_role_lib sqs/utils/assume_role_step \
         sqs/scripts/aws/do_tofu sqs/scripts/aws/delete_tfstate_objects tests/do_tofu_version.sh
```

- [ ] **Step 2: Write the SQS test helpers**

Create `sqs/scripts/tests/aws/helpers.bash`:

```bash
setup_mocks() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	SERVICE_PATH="$(cd "$TEST_DIR/../../.." && pwd)"
	SCRIPTS_DIR="$SERVICE_PATH/scripts/aws"
	MOCK_BIN="$BATS_TEST_TMPDIR/bin"
	MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
	VALUES="$BATS_TEST_TMPDIR/values.yaml"
	mkdir -p "$MOCK_BIN"
	: > "$MOCK_LOG"
	printf 'aws_profile: ""\n' > "$VALUES"
	export SERVICE_PATH SCRIPTS_DIR MOCK_LOG VALUES
	export PATH="$MOCK_BIN:$PATH"
	export MOCK_BUCKET_EXISTS="${MOCK_BUCKET_EXISTS:-0}"
	export MOCK_TOFU_OUTPUTS="${MOCK_TOFU_OUTPUTS:-{\}}"
	export MOCK_TOFU_EXIT="${MOCK_TOFU_EXIT:-0}"
	export MOCK_NP_PROVIDERS="${MOCK_NP_PROVIDERS:-{\"results\":[]\}}"
	export MOCK_NP_PROVIDER="${MOCK_NP_PROVIDER:-{\}}"
	export MOCK_LIST_VERSIONS="${MOCK_LIST_VERSIONS:-null}"
	unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN ACTION_SOURCE
	export SQS_S3_STATE_BUCKET="${SQS_S3_STATE_BUCKET-np-sqs-state}"

	cat > "$MOCK_BIN/aws" <<'MOCK'
#!/bin/bash
echo "aws $*" >> "$MOCK_LOG"
case "$*" in
	*"s3api head-bucket"*)
		[ "$MOCK_BUCKET_EXISTS" = "0" ] && printf '{\n    "BucketArn": "arn:aws:s3:::b",\n    "BucketRegion": "us-east-1",\n    "AccessPointAlias": false\n}\n'
		exit "$MOCK_BUCKET_EXISTS" ;;
	*"s3api list-object-versions"*) echo "$MOCK_LIST_VERSIONS" ;;
	*"s3api delete-objects"*)
		for arg in "$@"; do
			case "$arg" in file://*) [ -f "${arg#file://}" ] || { echo "missing delete file" >&2; exit 1; } ;; esac
		done ;;
esac
exit 0
MOCK

	cat > "$MOCK_BIN/np" <<'MOCK'
#!/bin/bash
echo "np $*" >> "$MOCK_LOG"
case "$*" in
	"provider list"*) echo "$MOCK_NP_PROVIDERS" ;;
	"provider read"*) echo "$MOCK_NP_PROVIDER" ;;
	*) echo "{}" ;;
esac
exit 0
MOCK

	cat > "$MOCK_BIN/tofu" <<'MOCK'
#!/bin/bash
echo "tofu $*" >> "$MOCK_LOG"
case "$1" in
	output) echo "$MOCK_TOFU_OUTPUTS" ;;
	init|apply|destroy) exit "$MOCK_TOFU_EXIT" ;;
esac
exit 0
MOCK

	chmod +x "$MOCK_BIN"/*
}

service_context() {
	jq -n \
		--arg id "0f3a6b1e-9c2d-4e8f-a1b2-c3d4e5f60718" \
		--arg slug "my-queue" \
		--argjson attrs "${1:-{\}}" \
		--argjson params "${2:-{\}}" \
		'{
			service: {
				id: $id,
				slug: $slug,
				name: "My Queue",
				nrn: "organization=1:account=2:namespace=3:application=4",
				attributes: $attrs
			},
			parameters: $params,
			tags: {
				account_id: "2",
				account: "acc",
				organization_id: "1",
				organization: "org",
				application_id: "4",
				application: "app",
				namespace_id: "3",
				namespace: "ns",
				scope_id: null
			}
		}'
}

link_context() {
	service_context "$1" "$2" | jq \
		--arg id "7d9e2f10-1234-4abc-9def-0123456789ab" \
		--arg slug "Orders API" \
		'.link = {id: $id, slug: $slug, attributes: {}}'
}

full_params() {
	jq -n '{
		aws_region: "us-west-2",
		queue_type: "standard",
		name: "orders"
	}'
}

run_script() {
	local script="$1"
	run bash -c "set -a; source '$SCRIPTS_DIR/$script' >'$BATS_TEST_TMPDIR/stdout' 2>'$BATS_TEST_TMPDIR/stderr'; rc=\$?; env > '$BATS_TEST_TMPDIR/env'; exit \$rc"
	captured_stdout=$(cat "$BATS_TEST_TMPDIR/stdout")
	captured_stderr=$(cat "$BATS_TEST_TMPDIR/stderr")
}

captured() {
	grep "^$1=" "$BATS_TEST_TMPDIR/env" | head -1 | cut -d= -f2-
}

tfvar() {
	jq -rc ".$1" "$(captured OUTPUT_DIR)/terraform.tfvars.json"
}

assert_equal() {
	if [ "$1" != "$2" ]; then
		echo "expected: $2"
		echo "actual:   $1"
		return 1
	fi
}

assert_contains() {
	if [[ "$1" != *"$2"* ]]; then
		echo "expected to contain: $2"
		echo "actual: $1"
		return 1
	fi
}

assert_not_contains() {
	if [[ "$1" == *"$2"* ]]; then
		echo "expected not to contain: $2"
		echo "actual: $1"
		return 1
	fi
}
```

- [ ] **Step 3: Run the copied tests**

Run: `bats sqs/utils/tests sqs/scripts/tests/aws/do_tofu.bats sqs/scripts/tests/aws/delete_tfstate_objects.bats`
Expected: all PASS. If a test fails because it still names something valkey-specific (a `Valkey` word in an assertion, a variable the new helper does not define), fix the `sed` result in that test file only; do not touch the scripts.

- [ ] **Step 4: Add the CI test workflow**

Create `.github/workflows/tests.yml`:

```yaml
name: tests

on:
  pull_request:
    branches:
      - main

jobs:
  do-tofu:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash tests/do_tofu_version.sh sqs/scripts/aws/do_tofu

  bats:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y bats jq
      - run: bats sqs/scripts/tests/aws/ sqs/utils/tests/
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(sqs): reuse the assume-role, tofu and state cleanup scripts from valkey

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `sqs_lib` — unit conversion and input validation

**Files:**
- Create: `sqs/scripts/aws/sqs_lib`
- Test: `sqs/scripts/tests/aws/sqs_lib.bats`

**Interfaces:**
- Consumes: `setup_mocks`, `assert_*` from Task 2.
- Produces (sourced by `build_context`; each prints its result on stdout and, on bad input, an `ERROR: …` line on stderr and returns 1):
  - `sqs_whole_number <label> <value> <min> <max>` → the number, normalized (`08` → `8`)
  - `sqs_to_seconds <label> <value> <unit> <min_s> <max_s> "<allowed units>"` → seconds
  - `sqs_queue_name <standard|fifo> <name>` → `np-<name>[.fifo]`
  - `sqs_access_principals <send|receive> <owner|principals> <csv>` → JSON array (`[]` for owner)
  - `sqs_parse_principals <label> <csv>` → JSON array of principal ARNs
  - `sqs_parse_queue_arns <label> <csv>` → JSON array of SQS ARNs
  - `sqs_require_kms_arn <arn>`, `sqs_require_queue_arn <label> <arn>`, `sqs_require_matching_dlq <true|false> <dlq_arn>` → no output, return code only
  - `sqs_user_tags_json <json value>` → JSON object

- [ ] **Step 1: Write the failing tests**

Create `sqs/scripts/tests/aws/sqs_lib.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
}

lib() {
	run bash -c "source '$SCRIPTS_DIR/sqs_lib'; $*"
}

@test "converts a value and unit to seconds" {
	lib "sqs_to_seconds 'visibility timeout' 5 minutes 0 43200 'seconds minutes hours'"
	[ "$status" -eq 0 ]
	assert_equal "$output" "300"
}

@test "accepts the exact limits of the range" {
	lib "sqs_to_seconds 'visibility timeout' 12 hours 0 43200 'seconds minutes hours'"
	[ "$status" -eq 0 ]
	assert_equal "$output" "43200"
	lib "sqs_to_seconds 'message retention period' 14 days 60 1209600 'seconds minutes hours days'"
	[ "$status" -eq 0 ]
	assert_equal "$output" "1209600"
	lib "sqs_to_seconds 'message retention period' 1 minutes 60 1209600 'seconds minutes hours days'"
	[ "$status" -eq 0 ]
	assert_equal "$output" "60"
}

@test "rejects a value above the range and says what it converted to" {
	lib "sqs_to_seconds 'visibility timeout' 13 hours 0 43200 'seconds minutes hours'"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: visibility timeout must be between 0 and 43200 seconds, got 46800 (13 hours)"
}

@test "rejects a value below the range" {
	lib "sqs_to_seconds 'message retention period' 30 seconds 60 1209600 'seconds minutes hours days'"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: message retention period must be between 60 and 1209600 seconds, got 30 (30 seconds)"
}

@test "rejects a unit the field does not offer" {
	lib "sqs_to_seconds 'delivery delay' 1 hours 0 900 'seconds minutes'"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: delivery delay unit must be one of: seconds minutes; got 'hours'"
}

@test "rejects blank, decimal, negative, exponent and oversized numbers" {
	for bad in "" "1.5" "-1" "1e3" "abc" "1234567890"; do
		lib "sqs_to_seconds 'visibility timeout' '$bad' seconds 0 43200 'seconds minutes hours'"
		[ "$status" -ne 0 ]
		assert_contains "$output" "ERROR: visibility timeout must be a whole number, got '$bad'"
	done
}

@test "reads zero-padded numbers as decimal instead of failing as octal" {
	lib "sqs_to_seconds 'visibility timeout' 08 seconds 0 43200 'seconds minutes hours'"
	[ "$status" -eq 0 ]
	assert_equal "$output" "8"
	lib "sqs_whole_number 'wait' 08 0 20"
	[ "$status" -eq 0 ]
	assert_equal "$output" "8"
}

@test "checks whole numbers against their range" {
	lib "sqs_whole_number 'maximum message size (KiB)' 1024 1 1024"
	[ "$status" -eq 0 ]
	assert_equal "$output" "1024"
	lib "sqs_whole_number 'maximum message size (KiB)' 1025 1 1024"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: maximum message size (KiB) must be between 1 and 1024, got 1025"
	lib "sqs_whole_number 'maximum message size (KiB)' 0 1 1024"
	[ "$status" -ne 0 ]
}

@test "names a Standard queue np-<name> and a FIFO queue np-<name>.fifo" {
	lib "sqs_queue_name standard orders"
	assert_equal "$output" "np-orders"
	lib "sqs_queue_name fifo orders_v2-eu"
	assert_equal "$output" "np-orders_v2-eu.fifo"
}

@test "a 72-character name fits the 80-character limit on a FIFO queue and 73 does not" {
	name72=$(printf 'a%.0s' $(seq 1 72))
	lib "sqs_queue_name fifo $name72"
	[ "$status" -eq 0 ]
	[ "${#output}" -eq 80 ]
	lib "sqs_queue_name fifo ${name72}a"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: name must be 1-72 characters"
}

@test "rejects names with spaces, dots or an empty name, and an unknown queue type" {
	for bad in "bad name" "has.dot" "" "ünï"; do
		lib "sqs_queue_name standard '$bad'"
		[ "$status" -ne 0 ]
		assert_contains "$output" "ERROR: name must be 1-72 characters"
	done
	lib "sqs_queue_name lifo orders"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: queue_type must be standard or fifo, got 'lifo'"
}

@test "owner access needs no principals" {
	lib "sqs_access_principals send owner ''"
	assert_equal "$output" "[]"
}

@test "principals are trimmed, empty entries dropped and bare account IDs expanded" {
	lib "sqs_access_principals send principals ' 111122223333 , arn:aws:iam::444455556666:role/worker ,'"
	[ "$status" -eq 0 ]
	assert_equal "$output" '["arn:aws:iam::111122223333:root","arn:aws:iam::444455556666:role/worker"]'
}

@test "a principals list with nothing but separators is rejected" {
	lib "sqs_access_principals receive principals ' , ,'"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: receive principals needs at least one account ID or ARN"
}

@test "rejects a principal that is not an account ID or an IAM ARN" {
	for bad in "12345" "arn:aws:s3:::bucket" "arn:aws:iam::111122223333:user/*" "*"; do
		lib "sqs_access_principals send principals '$bad'"
		[ "$status" -ne 0 ]
		assert_contains "$output" "ERROR: send principals entry '$bad' is not a 12-digit account ID or an IAM user, role or account ARN"
	done
}

@test "rejects an unknown access mode" {
	lib "sqs_access_principals send everyone ''"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: send access must be owner or principals, got 'everyone'"
}

@test "accepts KMS key and alias ARNs and rejects a bare key id" {
	lib "sqs_require_kms_arn arn:aws:kms:us-west-2:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"
	[ "$status" -eq 0 ]
	lib "sqs_require_kms_arn arn:aws:kms:us-west-2:111122223333:key/mrk-1234abcd12ab34cd56ef1234567890ab"
	[ "$status" -eq 0 ]
	lib "sqs_require_kms_arn arn:aws:kms:us-west-2:111122223333:alias/my-team/queue_key"
	[ "$status" -eq 0 ]
	lib "sqs_require_kms_arn 1234abcd-12ab-34cd-56ef-1234567890ab"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: kms_key_arn must be a KMS key or alias ARN"
}

@test "validates SQS queue ARNs, with and without the fifo suffix" {
	lib "sqs_require_queue_arn 'dead-letter queue ARN' arn:aws:sqs:us-west-2:111122223333:jobs-dlq"
	[ "$status" -eq 0 ]
	lib "sqs_require_queue_arn 'dead-letter queue ARN' arn:aws:sqs:us-west-2:111122223333:jobs-dlq.fifo"
	[ "$status" -eq 0 ]
	lib "sqs_require_queue_arn 'dead-letter queue ARN' https://sqs.us-west-2.amazonaws.com/111122223333/jobs"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: dead-letter queue ARN must be an SQS queue ARN"
}

@test "parses a list of source queue ARNs and rejects an empty one" {
	lib "sqs_parse_queue_arns 'redrive_source_queues' ' arn:aws:sqs:us-west-2:111122223333:a , arn:aws:sqs:us-west-2:111122223333:b '"
	[ "$status" -eq 0 ]
	assert_equal "$output" '["arn:aws:sqs:us-west-2:111122223333:a","arn:aws:sqs:us-west-2:111122223333:b"]'
	lib "sqs_parse_queue_arns 'redrive_source_queues' ''"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: redrive_source_queues needs at least one queue ARN"
}

@test "a FIFO queue needs a FIFO dead-letter queue and a Standard one a Standard one" {
	lib "sqs_require_matching_dlq true arn:aws:sqs:us-west-2:111122223333:jobs.fifo"
	[ "$status" -eq 0 ]
	lib "sqs_require_matching_dlq false arn:aws:sqs:us-west-2:111122223333:jobs"
	[ "$status" -eq 0 ]
	lib "sqs_require_matching_dlq true arn:aws:sqs:us-west-2:111122223333:jobs"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: a FIFO queue needs a FIFO dead-letter queue"
	lib "sqs_require_matching_dlq false arn:aws:sqs:us-west-2:111122223333:jobs.fifo"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: a Standard queue needs a Standard dead-letter queue"
}

@test "turns a list of key/value objects into a tag map" {
	lib "sqs_user_tags_json '[{\"key\":\"team\",\"value\":\"payments\"},{\"key\":\" env \",\"value\":\" prod \"},{\"key\":\"\",\"value\":\"x\"}]'"
	[ "$status" -eq 0 ]
	assert_equal "$output" '{"team":"payments","env":"prod"}'
}

@test "turns a key=value,key=value string into a tag map and keeps = inside values" {
	lib "sqs_user_tags_json '\"team=payments, env = prod,expr=a=b\"'"
	[ "$status" -eq 0 ]
	assert_equal "$output" '{"team":"payments","env":"prod","expr":"a=b"}'
}

@test "no tags is an empty map" {
	lib "sqs_user_tags_json '[]'"
	assert_equal "$output" "{}"
	lib "sqs_user_tags_json 'null'"
	assert_equal "$output" "{}"
}

@test "rejects tag keys that start with aws:" {
	lib "sqs_user_tags_json '[{\"key\":\"aws:team\",\"value\":\"x\"}]'"
	[ "$status" -ne 0 ]
	assert_contains "$output" "ERROR: tag keys must not start with aws:"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats sqs/scripts/tests/aws/sqs_lib.bats`
Expected: FAIL — `sqs_lib: No such file or directory` on every test.

- [ ] **Step 3: Write the library**

Create `sqs/scripts/aws/sqs_lib`:

```bash
#!/bin/bash
# Pure helpers for the SQS scripts: unit conversion, range checks and input validation.
# Sourced by build_context. Every function prints its result on stdout; on invalid
# input it prints "ERROR: ..." on stderr and returns 1.

SQS_KMS_ARN_PATTERN='^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:(key/[A-Za-z0-9-]+|alias/[A-Za-z0-9/_-]+)$'
SQS_QUEUE_ARN_PATTERN='^arn:aws[a-z-]*:sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]{1,80}(\.fifo)?$'
SQS_PRINCIPAL_ARN_PATTERN='^arn:aws[a-z-]*:iam::[0-9]{12}:(root|(user|role)/[A-Za-z0-9+=.@_/-]+)$'

sqs_unit_factor() {
  case "$1" in
    seconds) echo 1 ;;
    minutes) echo 60 ;;
    hours) echo 3600 ;;
    days) echo 86400 ;;
    *) return 1 ;;
  esac
}

sqs_whole_number() {
  local label="$1" value="$2" min="$3" max="$4" number
  if ! [[ "$value" =~ ^[0-9]{1,9}$ ]]; then
    echo "ERROR: ${label} must be a whole number, got '${value}'" >&2
    return 1
  fi
  number=$((10#$value))
  if [ "$number" -lt "$min" ] || [ "$number" -gt "$max" ]; then
    echo "ERROR: ${label} must be between ${min} and ${max}, got ${number}" >&2
    return 1
  fi
  echo "$number"
}

sqs_to_seconds() {
  local label="$1" value="$2" unit="$3" min="$4" max="$5" allowed="$6"
  local factor seconds
  if [[ " $allowed " != *" $unit "* ]]; then
    echo "ERROR: ${label} unit must be one of: ${allowed}; got '${unit}'" >&2
    return 1
  fi
  if ! [[ "$value" =~ ^[0-9]{1,9}$ ]]; then
    echo "ERROR: ${label} must be a whole number, got '${value}'" >&2
    return 1
  fi
  factor=$(sqs_unit_factor "$unit")
  seconds=$((10#$value * factor))
  if [ "$seconds" -lt "$min" ] || [ "$seconds" -gt "$max" ]; then
    echo "ERROR: ${label} must be between ${min} and ${max} seconds, got ${seconds} (${value} ${unit})" >&2
    return 1
  fi
  echo "$seconds"
}

sqs_queue_name() {
  local type="$1" name="$2"
  if ! [[ "$name" =~ ^[A-Za-z0-9_-]{1,72}$ ]]; then
    echo "ERROR: name must be 1-72 characters: letters, numbers, hyphens and underscores; got '${name}'" >&2
    return 1
  fi
  case "$type" in
    standard) echo "np-${name}" ;;
    fifo) echo "np-${name}.fifo" ;;
    *)
      echo "ERROR: queue_type must be standard or fifo, got '${type}'" >&2
      return 1
      ;;
  esac
}

sqs_parse_principals() {
  local label="$1" csv="$2" item items
  local principals=()
  # read -a splits on commas without expanding globs such as a lone "*"
  IFS=',' read -ra items <<< "$csv"
  for item in ${items[@]+"${items[@]}"}; do
    item="${item//[[:space:]]/}"
    [ -n "$item" ] || continue
    if [[ "$item" =~ ^[0-9]{12}$ ]]; then
      principals+=("arn:aws:iam::${item}:root")
    elif [[ "$item" =~ $SQS_PRINCIPAL_ARN_PATTERN ]]; then
      principals+=("$item")
    else
      echo "ERROR: ${label} entry '${item}' is not a 12-digit account ID or an IAM user, role or account ARN" >&2
      return 1
    fi
  done
  if [ "${#principals[@]}" -eq 0 ]; then
    echo "ERROR: ${label} needs at least one account ID or ARN" >&2
    return 1
  fi
  printf '%s\n' "${principals[@]}" | jq -R . | jq -sc .
}

sqs_access_principals() {
  local label="$1" mode="$2" csv="$3"
  case "$mode" in
    owner) echo '[]' ;;
    principals) sqs_parse_principals "${label} principals" "$csv" ;;
    *)
      echo "ERROR: ${label} access must be owner or principals, got '${mode}'" >&2
      return 1
      ;;
  esac
}

sqs_require_kms_arn() {
  local arn="$1"
  if ! [[ "$arn" =~ $SQS_KMS_ARN_PATTERN ]]; then
    echo "ERROR: kms_key_arn must be a KMS key or alias ARN (arn:aws:kms:<region>:<account>:key/<id> or .../alias/<name>), got '${arn}'" >&2
    return 1
  fi
}

sqs_require_queue_arn() {
  local label="$1" arn="$2"
  if ! [[ "$arn" =~ $SQS_QUEUE_ARN_PATTERN ]]; then
    echo "ERROR: ${label} must be an SQS queue ARN (arn:aws:sqs:<region>:<account>:<name>), got '${arn}'" >&2
    return 1
  fi
}

sqs_parse_queue_arns() {
  local label="$1" csv="$2" item items
  local arns=()
  IFS=',' read -ra items <<< "$csv"
  for item in ${items[@]+"${items[@]}"}; do
    item="${item//[[:space:]]/}"
    [ -n "$item" ] || continue
    sqs_require_queue_arn "${label} entry" "$item" || return 1
    arns+=("$item")
  done
  if [ "${#arns[@]}" -eq 0 ]; then
    echo "ERROR: ${label} needs at least one queue ARN" >&2
    return 1
  fi
  printf '%s\n' "${arns[@]}" | jq -R . | jq -sc .
}

sqs_require_matching_dlq() {
  local fifo="$1" dlq_arn="$2"
  local dlq_is_fifo=false
  if [[ "$dlq_arn" == *.fifo ]]; then
    dlq_is_fifo=true
  fi
  if [ "$fifo" = "true" ] && [ "$dlq_is_fifo" = "false" ]; then
    echo "ERROR: a FIFO queue needs a FIFO dead-letter queue, got '${dlq_arn}'" >&2
    return 1
  fi
  if [ "$fifo" = "false" ] && [ "$dlq_is_fifo" = "true" ]; then
    echo "ERROR: a Standard queue needs a Standard dead-letter queue, got '${dlq_arn}'" >&2
    return 1
  fi
}

sqs_user_tags_json() {
  local raw="$1" tags
  tags=$(echo "$raw" | jq -c '
    def trim: gsub("^\\s+|\\s+$"; "");
    if type == "array" then
      map(select((.key // "") != "") | {(.key | trim): ((.value // "") | tostring | trim)}) | add // {}
    elif type == "string" then
      split(",") | map(select(trim != "") | split("=") | {(.[0] | trim): (.[1:] | join("=") | trim)}) | add // {}
    else {} end')
  if echo "$tags" | jq -e 'keys | any(startswith("aws:"))' >/dev/null; then
    echo "ERROR: tag keys must not start with aws:" >&2
    return 1
  fi
  echo "$tags"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats sqs/scripts/tests/aws/sqs_lib.bats`
Expected: all PASS. If the `ünï` case fails because the shell locale makes `[A-Za-z]` match accented letters, replace the two `[A-Za-z0-9_-]` classes in `sqs_queue_name` and the queue ARN pattern with `[a-zA-Z0-9_-]` under `LC_ALL=C` by adding `LC_ALL=C` in front of the `[[ ]]` comparison — do not loosen the test.

- [ ] **Step 5: Commit**

```bash
git add sqs/scripts/aws/sqs_lib sqs/scripts/tests/aws/sqs_lib.bats
git commit -m "$(cat <<'EOF'
feat(sqs): add the input conversion and validation library

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `build_context`

**Files:**
- Create: `sqs/scripts/aws/build_context`
- Test: `sqs/scripts/tests/aws/build_context.bats`

**Interfaces:**
- Consumes: everything `sqs_lib` produces (Task 3); `SQS_S3_STATE_BUCKET`, `VALUES`, `CONTEXT`, `SERVICE_PATH`, optional `ACTION_SOURCE=link`.
- Produces (exported): `OUTPUT_DIR`, `REGION`, `TFSTATE_BUCKET`, `TFSTATE_KEY_PREFIX`, `SERVICE_ID`, `QUEUE_NAME`. Service actions also export `TOFU_MODULE_DIR`, `TOFU_INIT_VARIABLES`, `TOFU_VARIABLES` and write `$OUTPUT_DIR/terraform.tfvars.json`. Link actions also export `LINK_ID`, `LINK_USER_NAME`.
- `terraform.tfvars.json` keys (must match `sqs/deployment/variables.tf` in Task 5): `service_id`, `region`, `queue_name`, `fifo` (bool), `tags` (map), `visibility_timeout_seconds`, `message_retention_seconds`, `delay_seconds`, `max_message_size_bytes`, `receive_wait_time_seconds`, `encryption_key_type` (`sse-sqs|sse-kms`), `kms_key_arn` (`""` unless sse-kms), `kms_data_key_reuse_seconds`, `send_principals` (array), `receive_principals` (array), `redrive_allow` (`disabled|allow_all|by_queue|deny_all`), `redrive_source_queue_arns` (array), `dlq_arn` (`""` when disabled), `dlq_max_receives`.

- [ ] **Step 1: Write the failing tests**

Create `sqs/scripts/tests/aws/build_context.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
	export CONTEXT
	CONTEXT=$(service_context '{}' "$(full_params)")
	rm -rf /tmp/np-service-0f3a6b1e-9c2d-4e8f-a1b2-c3d4e5f60718
}

with_params() {
	CONTEXT=$(echo "$CONTEXT" | jq "$1")
}

@test "names a Standard queue np-<name> and exports it" {
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured QUEUE_NAME)" "np-orders"
	assert_equal "$(tfvar queue_name)" "np-orders"
	assert_equal "$(tfvar fifo)" "false"
}

@test "names a FIFO queue np-<name>.fifo" {
	with_params '.parameters.queue_type = "fifo"'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured QUEUE_NAME)" "np-orders.fifo"
	assert_equal "$(tfvar fifo)" "true"
}

@test "keeps the queue name stored in the attributes when the parameters change" {
	CONTEXT=$(service_context '{"queue_name":"np-orders.fifo"}' '{"aws_region":"us-west-2","queue_type":"standard","name":"renamed"}')
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured QUEUE_NAME)" "np-orders.fifo"
	assert_equal "$(tfvar fifo)" "true"
}

@test "rejects an invalid or missing name" {
	with_params '.parameters.name = "bad name!"'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: name must be 1-72 characters"

	with_params 'del(.parameters.name)'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: name must be 1-72 characters"
}

@test "applies the documented defaults" {
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar visibility_timeout_seconds)" "30"
	assert_equal "$(tfvar message_retention_seconds)" "345600"
	assert_equal "$(tfvar delay_seconds)" "0"
	assert_equal "$(tfvar max_message_size_bytes)" "1048576"
	assert_equal "$(tfvar receive_wait_time_seconds)" "0"
	assert_equal "$(tfvar encryption_key_type)" "sse-sqs"
	assert_equal "$(tfvar kms_key_arn)" ""
	assert_equal "$(tfvar kms_data_key_reuse_seconds)" "300"
	assert_equal "$(tfvar send_principals)" "[]"
	assert_equal "$(tfvar receive_principals)" "[]"
	assert_equal "$(tfvar redrive_allow)" "disabled"
	assert_equal "$(tfvar redrive_source_queue_arns)" "[]"
	assert_equal "$(tfvar dlq_arn)" ""
	assert_equal "$(tfvar dlq_max_receives)" "10"
}

@test "converts every value and unit the developer picks" {
	with_params '.parameters += {
		visibility_timeout_value: 2, visibility_timeout_unit: "hours",
		message_retention_value: 90, message_retention_unit: "minutes",
		delivery_delay_value: 5, delivery_delay_unit: "minutes",
		max_message_size_kib: 256,
		receive_wait_time_seconds: 20
	}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar visibility_timeout_seconds)" "7200"
	assert_equal "$(tfvar message_retention_seconds)" "5400"
	assert_equal "$(tfvar delay_seconds)" "300"
	assert_equal "$(tfvar max_message_size_bytes)" "262144"
	assert_equal "$(tfvar receive_wait_time_seconds)" "20"
}

@test "accepts the lowest values of every range" {
	with_params '.parameters += {
		visibility_timeout_value: 0, message_retention_value: 1, message_retention_unit: "minutes",
		delivery_delay_value: 0, max_message_size_kib: 1, receive_wait_time_seconds: 0
	}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar visibility_timeout_seconds)" "0"
	assert_equal "$(tfvar message_retention_seconds)" "60"
	assert_equal "$(tfvar max_message_size_bytes)" "1024"
}

@test "rejects values outside the AWS ranges" {
	with_params '.parameters += {visibility_timeout_value: 13, visibility_timeout_unit: "hours"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: visibility timeout must be between 0 and 43200 seconds, got 46800 (13 hours)"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {message_retention_value: 30, message_retention_unit: "seconds"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: message retention period must be between 60 and 1209600 seconds"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {message_retention_value: 15, message_retention_unit: "days"}'
	run_script build_context
	[ "$status" -ne 0 ]

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {delivery_delay_value: 16, delivery_delay_unit: "minutes"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: delivery delay must be between 0 and 900 seconds, got 960 (16 minutes)"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {max_message_size_kib: 1025}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: maximum message size (KiB) must be between 1 and 1024, got 1025"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {receive_wait_time_seconds: 21}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: receive message wait time (seconds) must be between 0 and 20, got 21"
}

@test "rejects a unit the field does not offer and a decimal value" {
	with_params '.parameters += {delivery_delay_value: 1, delivery_delay_unit: "hours"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: delivery delay unit must be one of: seconds minutes"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {visibility_timeout_value: 1.5}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "must be a whole number, got '1.5'"
}

@test "SSE-KMS carries the key ARN and the data key reuse period" {
	with_params '.parameters += {
		encryption_key_type: "sse-kms",
		kms_key_arn: "arn:aws:kms:us-west-2:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab",
		data_key_reuse_value: 1, data_key_reuse_unit: "hours"
	}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar encryption_key_type)" "sse-kms"
	assert_equal "$(tfvar kms_key_arn)" "arn:aws:kms:us-west-2:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"
	assert_equal "$(tfvar kms_data_key_reuse_seconds)" "3600"
}

@test "SSE-KMS accepts an alias ARN" {
	with_params '.parameters += {encryption_key_type: "sse-kms", kms_key_arn: "arn:aws:kms:us-west-2:111122223333:alias/queues"}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar kms_key_arn)" "arn:aws:kms:us-west-2:111122223333:alias/queues"
}

@test "SSE-KMS rejects a missing or malformed key and an out-of-range reuse period" {
	with_params '.parameters += {encryption_key_type: "sse-kms"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: kms_key_arn must be a KMS key or alias ARN"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {encryption_key_type: "sse-kms", kms_key_arn: "1234abcd-12ab-34cd-56ef-1234567890ab"}'
	run_script build_context
	[ "$status" -ne 0 ]

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {encryption_key_type: "sse-kms", kms_key_arn: "arn:aws:kms:us-west-2:111122223333:alias/queues", data_key_reuse_value: 25, data_key_reuse_unit: "hours"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: data key reuse period must be between 60 and 86400 seconds, got 90000 (25 hours)"
}

@test "SSE-SQS ignores a leftover key ARN, and an unknown key type is rejected" {
	with_params '.parameters += {encryption_key_type: "sse-sqs", kms_key_arn: "garbage"}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar kms_key_arn)" ""

	with_params '.parameters.encryption_key_type = "sse-foo"'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: encryption_key_type must be sse-sqs or sse-kms, got 'sse-foo'"
}

@test "send and receive principals are normalized, owner access stays empty" {
	with_params '.parameters += {
		send_access: "principals", send_principals: " 111122223333 , arn:aws:iam::444455556666:role/worker ,",
		receive_access: "owner", receive_principals: "ignored"
	}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar send_principals)" '["arn:aws:iam::111122223333:root","arn:aws:iam::444455556666:role/worker"]'
	assert_equal "$(tfvar receive_principals)" "[]"
}

@test "principals mode with an empty or invalid list is rejected" {
	with_params '.parameters += {receive_access: "principals", receive_principals: ""}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: receive principals needs at least one account ID or ARN"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {send_access: "principals", send_principals: "nope"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: send principals entry 'nope' is not a 12-digit account ID"
}

@test "redrive allow By queue carries the source queue ARNs" {
	with_params '.parameters += {
		redrive_allow: "by_queue",
		redrive_source_queues: "arn:aws:sqs:us-west-2:111122223333:jobs, arn:aws:sqs:us-west-2:111122223333:jobs-2"
	}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar redrive_allow)" "by_queue"
	assert_equal "$(tfvar redrive_source_queue_arns)" '["arn:aws:sqs:us-west-2:111122223333:jobs","arn:aws:sqs:us-west-2:111122223333:jobs-2"]'
}

@test "redrive allow All and Deny need no queues; By queue without queues and unknown modes are rejected" {
	with_params '.parameters.redrive_allow = "allow_all"'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar redrive_allow)" "allow_all"
	assert_equal "$(tfvar redrive_source_queue_arns)" "[]"

	with_params '.parameters.redrive_allow = "by_queue"'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: redrive_source_queues needs at least one queue ARN"

	with_params '.parameters.redrive_allow = "sometimes"'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: redrive_allow must be disabled, allow_all, by_queue or deny_all, got 'sometimes'"
}

@test "an enabled dead-letter queue carries its ARN and max receives" {
	with_params '.parameters += {dlq_enabled: "enabled", dlq_arn: "arn:aws:sqs:us-west-2:111122223333:orders-dlq", dlq_max_receives: 5}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar dlq_arn)" "arn:aws:sqs:us-west-2:111122223333:orders-dlq"
	assert_equal "$(tfvar dlq_max_receives)" "5"
}

@test "an enabled dead-letter queue needs a valid ARN, a sane max receives and the same queue type" {
	with_params '.parameters += {dlq_enabled: "enabled"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: dead-letter queue ARN must be an SQS queue ARN"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {dlq_enabled: "enabled", dlq_arn: "arn:aws:sqs:us-west-2:111122223333:orders-dlq", dlq_max_receives: 0}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: maximum receives must be between 1 and 1000, got 0"

	CONTEXT=$(service_context '{}' "$(full_params)")
	with_params '.parameters += {queue_type: "fifo", dlq_enabled: "enabled", dlq_arn: "arn:aws:sqs:us-west-2:111122223333:orders-dlq"}'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: a FIFO queue needs a FIFO dead-letter queue"
}

@test "a disabled dead-letter queue ignores a leftover ARN" {
	with_params '.parameters += {dlq_enabled: "disabled", dlq_arn: "garbage"}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar dlq_arn)" ""
}

@test "merges the developer's tags under the platform tags, which cannot be overridden" {
	with_params '.parameters.tags = [{"key":"team","value":"payments"},{"key":"account_id","value":"spoofed"}]'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar tags.team)" "payments"
	assert_equal "$(tfvar tags.account_id)" "2"
	assert_equal "$(tfvar 'tags | has("scope_id")')" "false"
}

@test "accepts the tags as a key=value string" {
	with_params '.parameters.tags = "team=payments, env = prod"'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar tags.team)" "payments"
	assert_equal "$(tfvar tags.env)" "prod"
}

@test "rejects a tag key that starts with aws:" {
	with_params '.parameters.tags = [{"key":"aws:team","value":"x"}]'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: tag keys must not start with aws:"
}

@test "takes the region from the aws_region attribute without querying the account provider" {
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured REGION)" "us-west-2"
	assert_not_contains "$(cat "$MOCK_LOG")" "np provider"
}

@test "resolves the region from the account provider when the attribute is absent" {
	with_params 'del(.parameters.aws_region)'
	export MOCK_NP_PROVIDERS='{"results":[{"id":"prov-1","data_source":{"stored_keys":["account.region"]}}]}'
	export MOCK_NP_PROVIDER='{"attributes":{"account":{"region":"eu-central-1"}}}'
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured REGION)" "eu-central-1"
	assert_contains "$(cat "$MOCK_LOG")" "np provider list --nrn organization=1:account=2 --format json --limit 100"
}

@test "fails with a clear message when no region can be resolved" {
	with_params 'del(.parameters.aws_region)'
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: no account provider with account.region found for organization=1:account=2"
}

@test "keeps the service state under services/sqs/<service id>/" {
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured TFSTATE_BUCKET)" "np-sqs-state"
	assert_equal "$(captured TFSTATE_KEY_PREFIX)" "services/sqs/0f3a6b1e-9c2d-4e8f-a1b2-c3d4e5f60718/"
	assert_contains "$(captured TOFU_INIT_VARIABLES)" "-backend-config=key=services/sqs/0f3a6b1e-9c2d-4e8f-a1b2-c3d4e5f60718/terraform.tfstate"
	assert_contains "$(captured TOFU_INIT_VARIABLES)" "-backend-config=bucket=np-sqs-state"
	assert_equal "$(captured TOFU_MODULE_DIR)" "$SERVICE_PATH/deployment"
	assert_contains "$(captured TOFU_VARIABLES)" "-var-file=$(captured OUTPUT_DIR)/terraform.tfvars.json"
}

@test "fails when the state bucket variable is missing or the bucket is unreachable" {
	export SQS_S3_STATE_BUCKET=""
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: SQS_S3_STATE_BUCKET is not set."

	export SQS_S3_STATE_BUCKET="np-sqs-state"
	export MOCK_BUCKET_EXISTS=1
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: the state bucket np-sqs-state does not exist or is not reachable from us-west-2."
}

@test "a link action derives the link user and skips the queue settings" {
	export ACTION_SOURCE=link
	CONTEXT=$(link_context '{"queue_name":"np-orders"}' '{}')
	run_script build_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured LINK_ID)" "7d9e2f10-1234-4abc-9def-0123456789ab"
	assert_equal "$(captured LINK_USER_NAME)" "np-orders-api-7d9e2-user"
	assert_equal "$(captured QUEUE_NAME)" "np-orders"
	assert_equal "$(captured TOFU_VARIABLES)" ""
	[ ! -f "$(captured OUTPUT_DIR)/terraform.tfvars.json" ]
}

@test "a link action fails when the service has no queue yet" {
	export ACTION_SOURCE=link
	CONTEXT=$(link_context '{}' '{}')
	run_script build_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: the service has no queue_name attribute yet."
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats sqs/scripts/tests/aws/build_context.bats`
Expected: FAIL — `build_context: No such file or directory`.

- [ ] **Step 3: Write `build_context`**

Create `sqs/scripts/aws/build_context`:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sqs_lib
source "$SCRIPT_DIR/sqs_lib"

yaml_value() {
  local key="$1" default="$2" file="$3"
  local val
  val=$(grep "^${key}:" "$file" 2>/dev/null | sed 's/^[^:]*: *//;s/^"//;s/"$//' | head -1)
  echo "${val:-$default}"
}

short_name() {
  local input="$1" max_len="$2"
  echo "$input" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-"$max_len" | sed 's/^-*//;s/-*$//'
}

resource_name() {
  local label="$1" id="$2" max_label_len="$3" suffix="${4:-}"
  local short
  short=$(short_name "$label" "$max_label_len")
  echo "np-${short:+${short}-}${id:0:5}${suffix}"
}

resolve_region() {
  local from_attrs="$1" account_nrn="$2"
  if [ -n "$from_attrs" ]; then
    echo "$from_attrs"
    return 0
  fi

  if [ -z "$account_nrn" ]; then
    echo "ERROR: could not derive account NRN from .service.nrn in context" >&2
    return 1
  fi

  echo "Resolving region for account: ${account_nrn}" >&2

  local providers provider_id provider_data region
  providers=$(np provider list --nrn "$account_nrn" --format json --limit 100)
  provider_id=$(echo "$providers" \
    | jq -r '[(.results // [])[] | select((.data_source.stored_keys // []) | contains(["account.region"]))] | first | .id // ""')

  if [ -z "$provider_id" ] || [ "$provider_id" = "null" ]; then
    echo "ERROR: no account provider with account.region found for ${account_nrn}" >&2
    return 1
  fi

  provider_data=$(np provider read --id "$provider_id" --format json)
  region=$(echo "$provider_data" | jq -r '.attributes.account.region // ""')

  if [ -z "$region" ]; then
    echo "ERROR: account.region not found in provider ${provider_id}" >&2
    return 1
  fi

  echo "$region"
}

require_state_bucket() {
  local region="$1"

  if [ -z "${SQS_S3_STATE_BUCKET:-}" ]; then
    echo "ERROR: SQS_S3_STATE_BUCKET is not set." >&2
    echo "  The agent must provide the name of the S3 bucket holding the tofu state." >&2
    exit 1
  fi

  if ! aws s3api head-bucket --bucket "$SQS_S3_STATE_BUCKET" --region "$region" >/dev/null 2>&1; then
    echo "ERROR: the state bucket ${SQS_S3_STATE_BUCKET} does not exist or is not reachable from ${region}." >&2
    exit 1
  fi

  echo "Using state bucket: ${SQS_S3_STATE_BUCKET}"
}

attr() {
  echo "$SERVICE_ATTRS" | jq -r --arg key "$1" --arg default "${2:-}" \
    'if .[$key] == null or .[$key] == "" then $default else (.[$key] | tostring) end'
}

resolve_queue_name() {
  local existing
  existing=$(echo "$CONTEXT" | jq -r '.service.attributes.queue_name // ""')
  if [ -n "$existing" ]; then
    echo "Using existing queue_name from service attributes: ${existing}" >&2
    echo "$existing"
    return 0
  fi
  if [ "${ACTION_SOURCE:-}" = "link" ]; then
    echo "ERROR: the service has no queue_name attribute yet." >&2
    echo "  The queue must be created before a link can be established." >&2
    return 1
  fi
  sqs_queue_name "$(attr queue_type standard)" "$(attr name)"
}

write_queue_tfvars() {
  local fifo=false
  if [[ "$QUEUE_NAME" == *.fifo ]]; then
    fifo=true
  fi

  local visibility retention delay max_size_kib wait
  visibility=$(sqs_to_seconds "visibility timeout" "$(attr visibility_timeout_value 30)" "$(attr visibility_timeout_unit seconds)" 0 43200 "seconds minutes hours")
  retention=$(sqs_to_seconds "message retention period" "$(attr message_retention_value 4)" "$(attr message_retention_unit days)" 60 1209600 "seconds minutes hours days")
  delay=$(sqs_to_seconds "delivery delay" "$(attr delivery_delay_value 0)" "$(attr delivery_delay_unit seconds)" 0 900 "seconds minutes")
  max_size_kib=$(sqs_whole_number "maximum message size (KiB)" "$(attr max_message_size_kib 1024)" 1 1024)
  wait=$(sqs_whole_number "receive message wait time (seconds)" "$(attr receive_wait_time_seconds 0)" 0 20)

  local key_type kms_arn="" key_reuse=300
  key_type=$(attr encryption_key_type sse-sqs)
  case "$key_type" in
    sse-sqs) ;;
    sse-kms)
      kms_arn=$(attr kms_key_arn)
      sqs_require_kms_arn "$kms_arn"
      key_reuse=$(sqs_to_seconds "data key reuse period" "$(attr data_key_reuse_value 5)" "$(attr data_key_reuse_unit minutes)" 60 86400 "minutes hours")
      ;;
    *)
      echo "ERROR: encryption_key_type must be sse-sqs or sse-kms, got '${key_type}'" >&2
      return 1
      ;;
  esac

  local send_principals receive_principals
  send_principals=$(sqs_access_principals send "$(attr send_access owner)" "$(attr send_principals)")
  receive_principals=$(sqs_access_principals receive "$(attr receive_access owner)" "$(attr receive_principals)")

  local redrive_allow redrive_sources='[]'
  redrive_allow=$(attr redrive_allow disabled)
  case "$redrive_allow" in
    disabled | allow_all | deny_all) ;;
    by_queue) redrive_sources=$(sqs_parse_queue_arns "redrive_source_queues" "$(attr redrive_source_queues)") ;;
    *)
      echo "ERROR: redrive_allow must be disabled, allow_all, by_queue or deny_all, got '${redrive_allow}'" >&2
      return 1
      ;;
  esac

  local dlq_arn="" dlq_max_receives=10
  if [ "$(attr dlq_enabled disabled)" = "enabled" ]; then
    dlq_arn=$(attr dlq_arn)
    sqs_require_queue_arn "dead-letter queue ARN" "$dlq_arn"
    sqs_require_matching_dlq "$fifo" "$dlq_arn"
    dlq_max_receives=$(sqs_whole_number "maximum receives" "$(attr dlq_max_receives 10)" 1 1000)
  fi

  local user_tags platform_tags tags
  user_tags=$(sqs_user_tags_json "$(echo "$SERVICE_ATTRS" | jq -c '.tags // []')")
  platform_tags=$(echo "$CONTEXT" | jq -c '(.tags // {}) | with_entries(select(.value | type == "string"))')
  tags=$(jq -cn --argjson user "$user_tags" --argjson platform "$platform_tags" '$user + $platform')

  jq -n \
    --arg service_id "$SERVICE_ID" \
    --arg region "$REGION" \
    --arg queue_name "$QUEUE_NAME" \
    --argjson fifo "$fifo" \
    --argjson tags "$tags" \
    --argjson visibility "$visibility" \
    --argjson retention "$retention" \
    --argjson delay "$delay" \
    --argjson max_size_bytes "$((max_size_kib * 1024))" \
    --argjson wait "$wait" \
    --arg key_type "$key_type" \
    --arg kms_arn "$kms_arn" \
    --argjson key_reuse "$key_reuse" \
    --argjson send_principals "$send_principals" \
    --argjson receive_principals "$receive_principals" \
    --arg redrive_allow "$redrive_allow" \
    --argjson redrive_sources "$redrive_sources" \
    --arg dlq_arn "$dlq_arn" \
    --argjson dlq_max_receives "$dlq_max_receives" \
    '{
      service_id: $service_id,
      region: $region,
      queue_name: $queue_name,
      fifo: $fifo,
      tags: $tags,
      visibility_timeout_seconds: $visibility,
      message_retention_seconds: $retention,
      delay_seconds: $delay,
      max_message_size_bytes: $max_size_bytes,
      receive_wait_time_seconds: $wait,
      encryption_key_type: $key_type,
      kms_key_arn: $kms_arn,
      kms_data_key_reuse_seconds: $key_reuse,
      send_principals: $send_principals,
      receive_principals: $receive_principals,
      redrive_allow: $redrive_allow,
      redrive_source_queue_arns: $redrive_sources,
      dlq_arn: $dlq_arn,
      dlq_max_receives: $dlq_max_receives
    }' > "$OUTPUT_DIR/terraform.tfvars.json"
}

SERVICE_ID=$(echo "$CONTEXT" | jq -r '.service.id')
SERVICE_ATTRS=$(echo "$CONTEXT" | jq -c '(.service.attributes // {}) * (.parameters // {})')
export SERVICE_ID

AWS_PROFILE_VAL=$(yaml_value "aws_profile" "" "$VALUES")
if [ -n "$AWS_PROFILE_VAL" ]; then
  export AWS_PROFILE="$AWS_PROFILE_VAL"
fi

ACCOUNT_NRN=$(echo "$CONTEXT" | jq -r '.service.nrn // .entity_nrn // ""' | sed 's/:namespace=.*$//')
REGION=$(resolve_region "$(echo "$SERVICE_ATTRS" | jq -r '.aws_region // ""')" "$ACCOUNT_NRN")
echo "Using region: ${REGION}"
export REGION

require_state_bucket "$REGION"
TFSTATE_BUCKET="$SQS_S3_STATE_BUCKET"
TFSTATE_KEY_PREFIX="services/sqs/${SERVICE_ID}/"
export TFSTATE_BUCKET TFSTATE_KEY_PREFIX
echo "Using state prefix: ${TFSTATE_KEY_PREFIX}"

QUEUE_NAME=$(resolve_queue_name)
export QUEUE_NAME

export OUTPUT_DIR="/tmp/np-service-${SERVICE_ID}"
mkdir -p "$OUTPUT_DIR"

if [ "${ACTION_SOURCE:-}" = "link" ]; then
  LINK_ID=$(echo "$CONTEXT" | jq -r '.link.id // ""')
  LINK_LABEL=$(echo "$CONTEXT" | jq -r '.link.slug // .link.name // ""')
  LINK_USER_NAME=$(resource_name "$LINK_LABEL" "$LINK_ID" 26 "-user")
  echo "Link user name: ${LINK_USER_NAME}"
  export LINK_ID LINK_USER_NAME
else
  write_queue_tfvars

  export TOFU_MODULE_DIR="$SERVICE_PATH/deployment"
  export TOFU_INIT_VARIABLES="-backend-config=bucket=${TFSTATE_BUCKET} -backend-config=key=${TFSTATE_KEY_PREFIX}terraform.tfstate -backend-config=region=${REGION} -backend-config=use_lockfile=true"
  export TOFU_VARIABLES="-var-file=${OUTPUT_DIR}/terraform.tfvars.json"
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats sqs/scripts/tests/aws/build_context.bats`
Expected: all PASS. If the `tfvar 'tags | has("scope_id")'` assertion errors, change that helper call to `jq -r '.tags | has("scope_id")' "$(captured OUTPUT_DIR)/terraform.tfvars.json"`; the behavior under test is unchanged.

- [ ] **Step 5: Commit**

```bash
git add sqs/scripts/aws/build_context sqs/scripts/tests/aws/build_context.bats
git commit -m "$(cat <<'EOF'
feat(sqs): build the queue context and tofu variables from the service attributes

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: The `deployment/` OpenTofu module

**Files:**
- Create: `sqs/deployment/backend.tf`, `providers.tf`, `variables.tf`, `main.tf`, `outputs.tf`

**Interfaces:**
- Consumes: the `terraform.tfvars.json` keys listed in Task 4.
- Produces: outputs `queue_url`, `queue_arn`, `queue_name` (read by `write_service_outputs`, Task 6).

- [ ] **Step 1: Write the module**

`sqs/deployment/backend.tf`:

```hcl
terraform {
  backend "s3" {}
}
```

`sqs/deployment/providers.tf`:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}
```

`sqs/deployment/variables.tf`:

```hcl
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
```

`sqs/deployment/main.tf`:

```hcl
data "aws_caller_identity" "current" {}

locals {
  common_tags = merge(var.tags, {
    "managed-by" = "nullplatform"
    "service-id" = var.service_id
  })

  use_kms         = var.encryption_key_type == "sse-kms"
  owner_principal = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"

  send_actions = ["sqs:SendMessage"]
  receive_actions = [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:ChangeMessageVisibility",
    "sqs:GetQueueAttributes",
  ]
}

resource "aws_sqs_queue" "queue" {
  name       = var.queue_name
  fifo_queue = var.fifo

  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  delay_seconds              = var.delay_seconds
  max_message_size           = var.max_message_size_bytes
  receive_wait_time_seconds  = var.receive_wait_time_seconds

  sqs_managed_sse_enabled           = local.use_kms ? null : true
  kms_master_key_id                 = local.use_kms ? var.kms_key_arn : null
  kms_data_key_reuse_period_seconds = local.use_kms ? var.kms_data_key_reuse_seconds : null

  tags = local.common_tags
}

resource "aws_sqs_queue_policy" "queue" {
  queue_url = aws_sqs_queue.queue.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "OwnerSend"
          Effect    = "Allow"
          Principal = { AWS = local.owner_principal }
          Action    = local.send_actions
          Resource  = aws_sqs_queue.queue.arn
        },
        {
          Sid       = "OwnerReceive"
          Effect    = "Allow"
          Principal = { AWS = local.owner_principal }
          Action    = local.receive_actions
          Resource  = aws_sqs_queue.queue.arn
        },
      ],
      length(var.send_principals) > 0 ? [{
        Sid       = "PrincipalsSend"
        Effect    = "Allow"
        Principal = { AWS = var.send_principals }
        Action    = local.send_actions
        Resource  = aws_sqs_queue.queue.arn
      }] : [],
      length(var.receive_principals) > 0 ? [{
        Sid       = "PrincipalsReceive"
        Effect    = "Allow"
        Principal = { AWS = var.receive_principals }
        Action    = local.receive_actions
        Resource  = aws_sqs_queue.queue.arn
      }] : [],
    )
  })
}

resource "aws_sqs_queue_redrive_policy" "queue" {
  count = var.dlq_arn == "" ? 0 : 1

  queue_url = aws_sqs_queue.queue.url
  redrive_policy = jsonencode({
    deadLetterTargetArn = var.dlq_arn
    maxReceiveCount     = var.dlq_max_receives
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "queue" {
  count = var.redrive_allow == "disabled" ? 0 : 1

  queue_url = aws_sqs_queue.queue.url
  redrive_allow_policy = var.redrive_allow == "by_queue" ? jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = var.redrive_source_queue_arns
    }) : jsonencode({
    redrivePermission = var.redrive_allow == "allow_all" ? "allowAll" : "denyAll"
  })
}
```

`sqs/deployment/outputs.tf`:

```hcl
output "queue_url" {
  value       = aws_sqs_queue.queue.url
  description = "URL applications send to and receive from"
}

output "queue_arn" {
  value       = aws_sqs_queue.queue.arn
  description = "ARN of the queue"
}

output "queue_name" {
  value       = aws_sqs_queue.queue.name
  description = "Queue name, persisted in the service attributes so later actions reuse it"
}
```

- [ ] **Step 2: Format and validate**

Run:
```bash
tofu fmt -check -recursive sqs/deployment
tofu -chdir=sqs/deployment init -backend=false -input=false
tofu -chdir=sqs/deployment validate
```
Expected: `fmt` prints nothing (run `tofu fmt -recursive sqs/deployment` and re-check if it lists files); `validate` prints `Success! The configuration is valid.`

- [ ] **Step 3: Check the variables against what `build_context` writes**

Run: `jq -r 'keys[]' "$(ls -d /tmp/np-service-*/ | head -1)terraform.tfvars.json" | sort > /tmp/np-tfvars-keys.txt; grep -oE '^variable "[a-z_]+"' sqs/deployment/variables.tf | sed 's/variable "//;s/"//' | sort > /tmp/np-tf-vars.txt; diff /tmp/np-tfvars-keys.txt /tmp/np-tf-vars.txt && echo SAME`
Expected: `SAME`. (A `/tmp/np-service-*/terraform.tfvars.json` exists from the Task 4 test run; if not, run `bats sqs/scripts/tests/aws/build_context.bats` first.) A difference means a name drifted between the two tasks: fix `variables.tf`, not the tests.

- [ ] **Step 4: Plan the module against a stub (no AWS call)**

Run:
```bash
cd sqs/deployment
cat > /tmp/np-plan-check.tfvars.json <<'EOF'
{"service_id":"x","region":"us-east-1","queue_name":"np-orders.fifo","fifo":true,"encryption_key_type":"sse-kms","kms_key_arn":"arn:aws:kms:us-east-1:111122223333:alias/queues","send_principals":["arn:aws:iam::111122223333:root"],"redrive_allow":"by_queue","redrive_source_queue_arns":["arn:aws:sqs:us-east-1:111122223333:jobs.fifo"],"dlq_arn":"arn:aws:sqs:us-east-1:111122223333:dlq.fifo"}
EOF
tofu validate && tofu console -var-file=/tmp/np-plan-check.tfvars.json <<< 'local.use_kms'
cd ../..
```
Expected: `Success!` then `true`. (`tofu console` evaluates locals offline; it needs AWS credentials for the `aws_caller_identity` data source only when evaluating it, and `local.use_kms` does not.) If it asks for credentials, skip this step — the real run is Task 13.

- [ ] **Step 5: Commit**

```bash
git add sqs/deployment
git commit -m "$(cat <<'EOF'
feat(sqs): add the opentofu module that creates the queue and its policies

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `write_service_outputs`

**Files:**
- Create: `sqs/scripts/aws/write_service_outputs`
- Test: `sqs/scripts/tests/aws/write_service_outputs.bats`

**Interfaces:**
- Consumes: `OUTPUT_DIR`, `CONTEXT`; the `tofu output -json` keys `queue_url`, `queue_arn`, `queue_name` (Task 5).
- Produces: `np service patch --id <service id> --body {"attributes": {"queue_url","queue_arn","queue_name"}}`.

- [ ] **Step 1: Write the failing tests**

Create `sqs/scripts/tests/aws/write_service_outputs.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
	export CONTEXT
	CONTEXT=$(service_context '{}' '{}')
	export OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
	mkdir -p "$OUTPUT_DIR"
	export MOCK_TOFU_OUTPUTS='{"queue_url":{"value":"https://sqs.us-west-2.amazonaws.com/111122223333/np-orders"},"queue_arn":{"value":"arn:aws:sqs:us-west-2:111122223333:np-orders"},"queue_name":{"value":"np-orders"}}'
}

@test "patches the service attributes with the queue url, arn and name" {
	run_script write_service_outputs
	[ "$status" -eq 0 ]
	assert_contains "$(cat "$MOCK_LOG")" 'np service patch --id 0f3a6b1e-9c2d-4e8f-a1b2-c3d4e5f60718 --body {"attributes": {"queue_url":"https://sqs.us-west-2.amazonaws.com/111122223333/np-orders","queue_arn":"arn:aws:sqs:us-west-2:111122223333:np-orders","queue_name":"np-orders"}}'
}

@test "fails instead of leaving the service without a queue url" {
	export MOCK_TOFU_OUTPUTS='{"queue_arn":{"value":"arn:aws:sqs:us-west-2:111122223333:np-orders"},"queue_name":{"value":"np-orders"}}'
	run_script write_service_outputs
	[ "$status" -ne 0 ]
	assert_not_contains "$(cat "$MOCK_LOG")" "np service patch"
	assert_contains "$captured_stderr" "ERROR: No queue_url output found."
}

@test "fails when the queue arn or name is missing" {
	export MOCK_TOFU_OUTPUTS='{"queue_url":{"value":"https://sqs.us-west-2.amazonaws.com/111122223333/np-orders"}}'
	run_script write_service_outputs
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: No queue_arn output found."
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats sqs/scripts/tests/aws/write_service_outputs.bats`
Expected: FAIL — `write_service_outputs: No such file or directory`.

- [ ] **Step 3: Write the script**

Create `sqs/scripts/aws/write_service_outputs`:

```bash
#!/bin/bash
set -euo pipefail

cd "$OUTPUT_DIR"

SERVICE_ID=$(echo "$CONTEXT" | jq -r '.service.id')

OUTPUTS=$(tofu output -json 2>/dev/null || echo '{}')

QUEUE_URL=$(echo "$OUTPUTS"  | jq -r '.queue_url.value  // ""')
QUEUE_ARN=$(echo "$OUTPUTS"  | jq -r '.queue_arn.value  // ""')
QUEUE_NAME=$(echo "$OUTPUTS" | jq -r '.queue_name.value // ""')

for pair in "queue_url:$QUEUE_URL" "queue_arn:$QUEUE_ARN" "queue_name:$QUEUE_NAME"; do
  if [ -z "${pair#*:}" ]; then
    echo "ERROR: No ${pair%%:*} output found." >&2
    echo "  Writing the service without it would leave applications with no queue to reach." >&2
    exit 1
  fi
done

ATTRIBUTES=$(jq -n -c \
  --arg queue_url  "$QUEUE_URL" \
  --arg queue_arn  "$QUEUE_ARN" \
  --arg queue_name "$QUEUE_NAME" \
  '{
    queue_url:  $queue_url,
    queue_arn:  $queue_arn,
    queue_name: $queue_name
  }')

echo "Writing service attributes for service ${SERVICE_ID}:"
echo "$ATTRIBUTES" | jq .

np service patch --id "$SERVICE_ID" --body "{\"attributes\": $ATTRIBUTES}"

echo "Service attributes updated."
```

Run: `chmod +x sqs/scripts/aws/write_service_outputs`

- [ ] **Step 4: Run to verify it passes**

Run: `bats sqs/scripts/tests/aws/write_service_outputs.bats`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add sqs/scripts/aws/write_service_outputs sqs/scripts/tests/aws/write_service_outputs.bats
git commit -m "$(cat <<'EOF'
feat(sqs): write the queue url, arn and name back to the service

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Service workflows and their wiring test

**Files:**
- Create: `sqs/workflows/create.yaml`, `update.yaml`, `delete.yaml`, `read.yaml` (replace the template placeholders)
- Delete: `sqs/scripts/example`
- Test: `sqs/scripts/tests/aws/workflows.bats`

**Interfaces:**
- Consumes: `assume_role_step`, `build_context`, `do_tofu`, `write_service_outputs`, `delete_tfstate_objects` (Tasks 2, 4, 6).
- Produces: workflow files that the template's `entrypoint/service` runs as `workflows/<action>.yaml`. Link workflows are added in Task 8, and `workflows.bats` is re-run there.

- [ ] **Step 1: Write the wiring test (it covers every workflow that exists)**

Create `sqs/scripts/tests/aws/workflows.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
}

referenced_files() {
	grep -hoE 'file: \$SERVICE_PATH/[^ ]+' "$SERVICE_PATH"/workflows/*.yaml | sed 's|file: \$SERVICE_PATH/||' | sort -u
}

@test "every script a workflow references exists and is executable" {
	[ -n "$(referenced_files)" ]
	for rel in $(referenced_files); do
		[ -x "$SERVICE_PATH/$rel" ] || { echo "missing or not executable: $rel"; return 1; }
	done
}

@test "every workflow is valid YAML-shaped: it starts with steps and each step has a name and a type" {
	for f in "$SERVICE_PATH"/workflows/*.yaml; do
		head -1 "$f" | grep -q '^steps:$' || { echo "$f does not start with steps:"; return 1; }
		[ "$(grep -c '^  - name:' "$f")" -eq "$(grep -c '^    type: script$' "$f")" ] || { echo "$f: name/type mismatch"; return 1; }
	done
}

@test "create and update provision with apply, delete destroys and then cleans the state" {
	for action in create update; do
		grep -q 'TOFU_ACTION: apply' "$SERVICE_PATH/workflows/$action.yaml"
		grep -q 'write_service_outputs' "$SERVICE_PATH/workflows/$action.yaml"
	done
	grep -q 'TOFU_ACTION: destroy' "$SERVICE_PATH/workflows/delete.yaml"
	grep -q 'delete_tfstate_objects' "$SERVICE_PATH/workflows/delete.yaml"
}

@test "every workflow that touches AWS assumes the role first" {
	for f in create update delete; do
		[ "$(grep -m1 'file:' "$SERVICE_PATH/workflows/$f.yaml")" = '    file: $SERVICE_PATH/utils/assume_role_step' ]
	done
}

@test "the template placeholder script is gone" {
	[ ! -e "$SERVICE_PATH/scripts/example" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats sqs/scripts/tests/aws/workflows.bats`
Expected: FAIL (the placeholder workflows reference `scripts/example`, have no `assume_role_step`).

- [ ] **Step 3: Write the workflows**

`sqs/workflows/create.yaml` (and an identical `update.yaml`):

```yaml
steps:
  - name: assume role
    type: script
    file: $SERVICE_PATH/utils/assume_role_step
    output:
      - name: AWS_ACCESS_KEY_ID
        type: environment
      - name: AWS_SECRET_ACCESS_KEY
        type: environment
      - name: AWS_SESSION_TOKEN
        type: environment

  - name: build context
    type: script
    file: $SERVICE_PATH/scripts/aws/build_context
    output:
      - name: OUTPUT_DIR
        type: environment
      - name: REGION
        type: environment
      - name: TFSTATE_BUCKET
        type: environment
      - name: TFSTATE_KEY_PREFIX
        type: environment
      - name: TOFU_MODULE_DIR
        type: environment
      - name: TOFU_INIT_VARIABLES
        type: environment
      - name: TOFU_VARIABLES
        type: environment

  - name: tofu
    type: script
    file: $SERVICE_PATH/scripts/aws/do_tofu
    configuration:
      TOFU_ACTION: apply

  - name: write service outputs
    type: script
    file: $SERVICE_PATH/scripts/aws/write_service_outputs
```

`sqs/workflows/delete.yaml`:

```yaml
steps:
  - name: assume role
    type: script
    file: $SERVICE_PATH/utils/assume_role_step
    output:
      - name: AWS_ACCESS_KEY_ID
        type: environment
      - name: AWS_SECRET_ACCESS_KEY
        type: environment
      - name: AWS_SESSION_TOKEN
        type: environment

  - name: build context
    type: script
    file: $SERVICE_PATH/scripts/aws/build_context
    output:
      - name: OUTPUT_DIR
        type: environment
      - name: REGION
        type: environment
      - name: TFSTATE_BUCKET
        type: environment
      - name: TFSTATE_KEY_PREFIX
        type: environment
      - name: TOFU_MODULE_DIR
        type: environment
      - name: TOFU_INIT_VARIABLES
        type: environment
      - name: TOFU_VARIABLES
        type: environment

  - name: tofu
    type: script
    file: $SERVICE_PATH/scripts/aws/do_tofu
    configuration:
      TOFU_ACTION: destroy

  - name: cleanup tfstate objects
    type: script
    file: $SERVICE_PATH/scripts/aws/delete_tfstate_objects
```

`sqs/workflows/read.yaml`:

```yaml
steps:
  - name: read current state
    type: script
    script: |
      #!/bin/bash
      set -euo pipefail

      SERVICE_ATTRS=$(echo "$CONTEXT" | jq -r '.service.attributes // {}')

      RESULTS=$(echo "$SERVICE_ATTRS" | jq '{
        queue_url: (.queue_url // ""),
        queue_arn: (.queue_arn // "")
      }')

      echo "$RESULTS" | jq .

      np service action update --results "$RESULTS"
```

Note: the `read.yaml` inline step has no `file:` and a `script:` instead; `workflows.bats` counts `name`/`type` pairs, which still match.

- [ ] **Step 4: Remove the placeholder and run the tests**

```bash
git rm -q sqs/scripts/example sqs/workflows/link.yaml sqs/workflows/link-update.yaml sqs/workflows/unlink.yaml
bats sqs/scripts/tests/aws/workflows.bats
```
Expected: the 5 tests PASS. The template's three link workflows still point at the deleted `scripts/example`, so they go now and are recreated in Task 8.

- [ ] **Step 5: Commit**

```bash
git add -A sqs
git commit -m "$(cat <<'EOF'
feat(sqs): add the create, update, delete and read workflows

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Links — `permissions/` module, scripts and workflows

**Files:**
- Create: `sqs/permissions/backend.tf`, `providers.tf`, `variables.tf`, `main.tf`, `outputs.tf`
- Create: `sqs/scripts/aws/build_permissions_context`, `sqs/scripts/aws/write_link_outputs`
- Create: `sqs/workflows/link.yaml`, `link-update.yaml`, `unlink.yaml`
- Test: `sqs/scripts/tests/aws/build_permissions_context.bats`, `write_link_outputs.bats`

**Interfaces:**
- Consumes: from `build_context` (link mode): `OUTPUT_DIR`, `REGION`, `TFSTATE_BUCKET`, `TFSTATE_KEY_PREFIX`, `LINK_ID`, `LINK_USER_NAME`; from the service attributes: `queue_arn`, `encryption_key_type`, `kms_key_arn`.
- Produces: `permissions/` variables `link_id`, `region`, `user_name`, `queue_arn`, `kms_key_arn` (`""` unless SSE-KMS); outputs `user_name`, `access_key_id`, `secret_access_key` (sensitive). `write_link_outputs` patches the link with `access_key_id`, `secret_access_key`, `aws_region`.

- [ ] **Step 1: Write the failing tests**

`sqs/scripts/tests/aws/build_permissions_context.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
	export LINK_ID="7d9e2f10-1234-4abc-9def-0123456789ab"
	export LINK_USER_NAME="np-orders-api-7d9e2-user"
	export REGION="us-west-2"
	export TFSTATE_BUCKET="np-sqs-state"
	export TFSTATE_KEY_PREFIX="services/sqs/0f3a6b1e-9c2d-4e8f-a1b2-c3d4e5f60718/"
	export CONTEXT
	CONTEXT=$(link_context '{"queue_arn":"arn:aws:sqs:us-west-2:111122223333:np-orders","encryption_key_type":"sse-sqs"}' '{}')
	rm -rf "/tmp/np-link-${LINK_ID}"
}

@test "points tofu at the permissions module and the link's own state file" {
	run_script build_permissions_context
	[ "$status" -eq 0 ]
	assert_equal "$(captured TOFU_MODULE_DIR)" "$SERVICE_PATH/permissions"
	assert_equal "$(captured OUTPUT_DIR)" "/tmp/np-link-7d9e2f10-1234-4abc-9def-0123456789ab"
	assert_contains "$(captured TOFU_INIT_VARIABLES)" "-backend-config=key=services/sqs/0f3a6b1e-9c2d-4e8f-a1b2-c3d4e5f60718/links/7d9e2f10-1234-4abc-9def-0123456789ab.tfstate"
	assert_contains "$(captured TOFU_INIT_VARIABLES)" "-backend-config=bucket=np-sqs-state"
	assert_contains "$(captured TOFU_VARIABLES)" "-var-file=/tmp/np-link-7d9e2f10-1234-4abc-9def-0123456789ab/terraform.tfvars.json"
}

@test "passes the link, the user and the queue to the module" {
	run_script build_permissions_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar link_id)" "7d9e2f10-1234-4abc-9def-0123456789ab"
	assert_equal "$(tfvar user_name)" "np-orders-api-7d9e2-user"
	assert_equal "$(tfvar region)" "us-west-2"
	assert_equal "$(tfvar queue_arn)" "arn:aws:sqs:us-west-2:111122223333:np-orders"
	assert_equal "$(tfvar kms_key_arn)" ""
}

@test "passes the KMS key only when the queue uses SSE-KMS" {
	CONTEXT=$(link_context '{"queue_arn":"arn:aws:sqs:us-west-2:111122223333:np-orders","encryption_key_type":"sse-kms","kms_key_arn":"arn:aws:kms:us-west-2:111122223333:alias/queues"}' '{}')
	run_script build_permissions_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar kms_key_arn)" "arn:aws:kms:us-west-2:111122223333:alias/queues"

	CONTEXT=$(link_context '{"queue_arn":"arn:aws:sqs:us-west-2:111122223333:np-orders","encryption_key_type":"sse-sqs","kms_key_arn":"arn:aws:kms:us-west-2:111122223333:alias/stale"}' '{}')
	run_script build_permissions_context
	[ "$status" -eq 0 ]
	assert_equal "$(tfvar kms_key_arn)" ""
}

@test "fails when the service has no queue arn yet" {
	CONTEXT=$(link_context '{}' '{}')
	run_script build_permissions_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: the service has no queue_arn attribute yet."
}

@test "fails when build_context did not run first" {
	unset LINK_ID
	run_script build_permissions_context
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: LINK_ID is not set. build_context must run before this script."
}
```

`sqs/scripts/tests/aws/write_link_outputs.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
	export CONTEXT
	CONTEXT=$(link_context '{}' '{}')
	export REGION="us-west-2"
	export OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
	mkdir -p "$OUTPUT_DIR"
	export MOCK_TOFU_OUTPUTS='{"user_name":{"value":"np-orders-api-7d9e2-user"},"access_key_id":{"value":"AKIAEXAMPLEKEY"},"secret_access_key":{"value":"s3cr3tkeyvalue","sensitive":true}}'
}

@test "patches the link with the access key, the secret and the region" {
	run_script write_link_outputs
	[ "$status" -eq 0 ]
	assert_contains "$(cat "$MOCK_LOG")" 'np link patch --id 7d9e2f10-1234-4abc-9def-0123456789ab --body {"attributes": {"access_key_id":"AKIAEXAMPLEKEY","secret_access_key":"s3cr3tkeyvalue","aws_region":"us-west-2"}}'
	assert_contains "$captured_stdout" "Writing link attributes for link 7d9e2f10-1234-4abc-9def-0123456789ab (user: np-orders-api-7d9e2-user)"
}

@test "never prints the secret" {
	run_script write_link_outputs
	[ "$status" -eq 0 ]
	assert_not_contains "$captured_stdout" "s3cr3tkeyvalue"
	assert_not_contains "$captured_stderr" "s3cr3tkeyvalue"
}

@test "fails instead of writing a link the application cannot authenticate with" {
	export MOCK_TOFU_OUTPUTS='{"user_name":{"value":"np-orders-api-7d9e2-user"},"access_key_id":{"value":"AKIAEXAMPLEKEY"}}'
	run_script write_link_outputs
	[ "$status" -ne 0 ]
	assert_not_contains "$(cat "$MOCK_LOG")" "np link patch"
	assert_contains "$captured_stderr" "ERROR: the access key was created but its secret could not be read."

	export MOCK_TOFU_OUTPUTS='{"user_name":{"value":"np-orders-api-7d9e2-user"},"secret_access_key":{"value":"s3cr3tkeyvalue"}}'
	run_script write_link_outputs
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: No access_key_id output found."

	export MOCK_TOFU_OUTPUTS='{}'
	run_script write_link_outputs
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: No user_name output found."
}

@test "fails when the region was not resolved" {
	unset REGION
	run_script write_link_outputs
	[ "$status" -ne 0 ]
	assert_contains "$captured_stderr" "ERROR: REGION is not set. build_context must run before this script."
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats sqs/scripts/tests/aws/build_permissions_context.bats sqs/scripts/tests/aws/write_link_outputs.bats`
Expected: FAIL — scripts do not exist.

- [ ] **Step 3: Write the scripts**

`sqs/scripts/aws/build_permissions_context`:

```bash
#!/bin/bash
set -euo pipefail

for var in LINK_ID LINK_USER_NAME REGION TFSTATE_BUCKET TFSTATE_KEY_PREFIX; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: ${var} is not set. build_context must run before this script." >&2
    exit 1
  fi
done

QUEUE_ARN=$(echo "$CONTEXT" | jq -r '.service.attributes.queue_arn // ""')
if [ -z "$QUEUE_ARN" ]; then
  echo "ERROR: the service has no queue_arn attribute yet." >&2
  echo "  The queue must be created before a link can be established." >&2
  exit 1
fi

KMS_KEY_ARN=""
if [ "$(echo "$CONTEXT" | jq -r '.service.attributes.encryption_key_type // "sse-sqs"')" = "sse-kms" ]; then
  KMS_KEY_ARN=$(echo "$CONTEXT" | jq -r '.service.attributes.kms_key_arn // ""')
fi

echo "Link ${LINK_ID} -> queue ${QUEUE_ARN} (user: ${LINK_USER_NAME})"

export OUTPUT_DIR="/tmp/np-link-${LINK_ID}"
mkdir -p "$OUTPUT_DIR"

export TOFU_MODULE_DIR="$SERVICE_PATH/permissions"

export TOFU_INIT_VARIABLES="-backend-config=bucket=${TFSTATE_BUCKET} -backend-config=key=${TFSTATE_KEY_PREFIX}links/${LINK_ID}.tfstate -backend-config=region=${REGION} -backend-config=use_lockfile=true"

jq -n \
  --arg link_id "$LINK_ID" \
  --arg region "$REGION" \
  --arg user_name "$LINK_USER_NAME" \
  --arg queue_arn "$QUEUE_ARN" \
  --arg kms_key_arn "$KMS_KEY_ARN" \
  '{
    link_id: $link_id,
    region: $region,
    user_name: $user_name,
    queue_arn: $queue_arn,
    kms_key_arn: $kms_key_arn
  }' > "$OUTPUT_DIR/terraform.tfvars.json"

export TOFU_VARIABLES="-var-file=${OUTPUT_DIR}/terraform.tfvars.json"
```

`sqs/scripts/aws/write_link_outputs`:

```bash
#!/bin/bash
set -euo pipefail

if [ -z "${REGION:-}" ]; then
  echo "ERROR: REGION is not set. build_context must run before this script." >&2
  exit 1
fi

cd "$OUTPUT_DIR"

LINK_ID=$(echo "$CONTEXT" | jq -r '.link.id')

OUTPUTS=$(tofu output -json 2>/dev/null || echo '{}')

USER_NAME=$(echo "$OUTPUTS"         | jq -r '.user_name.value         // ""')
ACCESS_KEY_ID=$(echo "$OUTPUTS"     | jq -r '.access_key_id.value     // ""')
SECRET_ACCESS_KEY=$(echo "$OUTPUTS" | jq -r '.secret_access_key.value // ""')

if [ -z "$USER_NAME" ]; then
  echo "ERROR: No user_name output found." >&2
  exit 1
fi

if [ -z "$ACCESS_KEY_ID" ]; then
  echo "ERROR: No access_key_id output found." >&2
  exit 1
fi

if [ -z "$SECRET_ACCESS_KEY" ]; then
  echo "ERROR: the access key was created but its secret could not be read." >&2
  echo "  Writing the link without it would hand the application credentials" >&2
  echo "  it cannot authenticate with." >&2
  exit 1
fi

ATTRIBUTES=$(jq -n -c \
  --arg access_key_id     "$ACCESS_KEY_ID" \
  --arg secret_access_key "$SECRET_ACCESS_KEY" \
  --arg aws_region        "$REGION" \
  '{
    access_key_id:     $access_key_id,
    secret_access_key: $secret_access_key,
    aws_region:        $aws_region
  }')

echo "Writing link attributes for link ${LINK_ID} (user: ${USER_NAME})"

np link patch --id "$LINK_ID" --body "{\"attributes\": $ATTRIBUTES}"

echo "Link attributes updated."
```

Run: `chmod +x sqs/scripts/aws/build_permissions_context sqs/scripts/aws/write_link_outputs`

- [ ] **Step 4: Write the `permissions/` module**

`sqs/permissions/backend.tf`:

```hcl
terraform {
  backend "s3" {}
}
```

`sqs/permissions/providers.tf`:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}
```

`sqs/permissions/variables.tf`:

```hcl
variable "link_id" {
  type        = string
  description = "Nullplatform link ID"
}

variable "region" {
  type        = string
  description = "AWS region"
}

variable "user_name" {
  type        = string
  description = "IAM user created for this link, derived from the link slug and ID by build_context"

  validation {
    condition     = can(regex("^np-[a-z0-9-]{1,56}-user$", var.user_name))
    error_message = "user_name must look like np-<slug>-<id>-user: lowercase letters, numbers and hyphens, at most 64 characters"
  }
}

variable "queue_arn" {
  type        = string
  description = "ARN of the queue the link grants access to"
}

variable "kms_key_arn" {
  type        = string
  default     = ""
  description = "KMS key or alias ARN of an SSE-KMS queue. Empty for SSE-SQS queues"
}
```

`sqs/permissions/main.tf`:

```hcl
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
```

`sqs/permissions/outputs.tf`:

```hcl
output "user_name" {
  value       = aws_iam_user.link.name
  description = "IAM user created for this link"
}

output "access_key_id" {
  value       = aws_iam_access_key.link.id
  description = "Access key ID of the link user"
}

output "secret_access_key" {
  value       = aws_iam_access_key.link.secret
  sensitive   = true
  description = "Secret access key of the link user"
}
```

- [ ] **Step 5: Write the link workflows**

`sqs/workflows/link.yaml` and `sqs/workflows/link-update.yaml` (identical):

```yaml
steps:
  - name: assume role
    type: script
    file: $SERVICE_PATH/utils/assume_role_step
    output:
      - name: AWS_ACCESS_KEY_ID
        type: environment
      - name: AWS_SECRET_ACCESS_KEY
        type: environment
      - name: AWS_SESSION_TOKEN
        type: environment

  - name: build context
    type: script
    file: $SERVICE_PATH/scripts/aws/build_context
    output:
      - name: OUTPUT_DIR
        type: environment
      - name: REGION
        type: environment
      - name: TFSTATE_BUCKET
        type: environment
      - name: TFSTATE_KEY_PREFIX
        type: environment
      - name: LINK_ID
        type: environment
      - name: LINK_USER_NAME
        type: environment

  - name: build permissions context
    type: script
    file: $SERVICE_PATH/scripts/aws/build_permissions_context
    output:
      - name: OUTPUT_DIR
        type: environment
      - name: TOFU_MODULE_DIR
        type: environment
      - name: TOFU_INIT_VARIABLES
        type: environment
      - name: TOFU_VARIABLES
        type: environment

  - name: tofu
    type: script
    file: $SERVICE_PATH/scripts/aws/do_tofu
    configuration:
      TOFU_ACTION: apply

  - name: write link outputs
    type: script
    file: $SERVICE_PATH/scripts/aws/write_link_outputs
```

`sqs/workflows/unlink.yaml`: the same, with `TOFU_ACTION: destroy` and without the final `write link outputs` step.

- [ ] **Step 6: Make `workflows.bats` cover the link workflows, then validate and test**

Append to `sqs/scripts/tests/aws/workflows.bats`:

```bash
@test "link and link-update apply and write the link outputs, unlink destroys" {
	for action in link link-update; do
		grep -q 'TOFU_ACTION: apply' "$SERVICE_PATH/workflows/$action.yaml"
		grep -q 'build_permissions_context' "$SERVICE_PATH/workflows/$action.yaml"
		grep -q 'write_link_outputs' "$SERVICE_PATH/workflows/$action.yaml"
	done
	grep -q 'TOFU_ACTION: destroy' "$SERVICE_PATH/workflows/unlink.yaml"
	! grep -q 'write_link_outputs' "$SERVICE_PATH/workflows/unlink.yaml"
}
```
and change the last loop in the "assumes the role first" test to `for f in create update delete link link-update unlink; do`.

Run:
```bash
tofu fmt -check -recursive sqs/permissions
tofu -chdir=sqs/permissions init -backend=false -input=false
tofu -chdir=sqs/permissions validate
bats sqs/scripts/tests/aws/
```
Expected: `Success! The configuration is valid.`; every BATS test PASSES.

- [ ] **Step 7: Commit**

```bash
git add -A sqs
git commit -m "$(cat <<'EOF'
feat(sqs): add the link workflows with a per-link iam user and queue policy

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: The service and link specs

**Files:**
- Create: `sqs/specs/service-spec.json.tpl` (replaces the template's)
- Modify: `sqs/specs/links/connect.json.tpl`
- Modify: `sqs/values.yaml`
- Test: `sqs/scripts/tests/aws/specs.bats`

**Interfaces:**
- Consumes: attribute names and defaults from `build_context` (Task 4).
- Produces: `service-spec.json.tpl` with slug `aws-sqs`, `available_links: ["create-aws-sqs-link"]`; `links/connect.json.tpl` with slug `create-aws-sqs-link`.

- [ ] **Step 1: Write the failing tests**

Create `sqs/scripts/tests/aws/specs.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
	SPEC="$SERVICE_PATH/specs/service-spec.json.tpl"
	LINK="$SERVICE_PATH/specs/links/connect.json.tpl"
}

prop() {
	jq -r ".attributes.schema.properties.$1" "$SPEC"
}

@test "both specs are valid JSON with the schema under attributes.schema" {
	jq -e '.attributes.schema.type == "object"' "$SPEC"
	jq -e '.attributes.schema.type == "object"' "$LINK"
	run jq -e '.specification_schema' "$SPEC"
	[ "$status" -ne 0 ]
	run jq -e '.specification_schema' "$LINK"
	[ "$status" -ne 0 ]
}

@test "the service offers its link and the link slug matches" {
	assert_equal "$(jq -r .slug "$SPEC")" "aws-sqs"
	assert_equal "$(jq -r '.available_links[0]' "$SPEC")" "create-aws-sqs-link"
	assert_equal "$(jq -r .slug "$LINK")" "create-aws-sqs-link"
}

@test "the queue type and name can only be set on create" {
	assert_equal "$(prop 'queue_type.editableOn' | jq -c .)" '["create"]'
	assert_equal "$(prop 'name.editableOn' | jq -c .)" '["create"]'
	assert_equal "$(jq -c '.attributes.schema.required' "$SPEC")" '["queue_type","name"]'
}

@test "every other setting can be changed after creation" {
	for p in visibility_timeout_value visibility_timeout_unit message_retention_value message_retention_unit \
		delivery_delay_value delivery_delay_unit max_message_size_kib receive_wait_time_seconds \
		encryption_key_type kms_key_arn data_key_reuse_value data_key_reuse_unit \
		send_access send_principals receive_access receive_principals \
		redrive_allow redrive_source_queues dlq_enabled dlq_arn dlq_max_receives tags; do
		assert_equal "$(prop "$p.editableOn" | jq -c .)" '["create","update"]'
	done
}

@test "the defaults match the ones build_context applies" {
	assert_equal "$(prop 'queue_type.default')" "standard"
	assert_equal "$(prop 'visibility_timeout_value.default')" "30"
	assert_equal "$(prop 'visibility_timeout_unit.default')" "seconds"
	assert_equal "$(prop 'message_retention_value.default')" "4"
	assert_equal "$(prop 'message_retention_unit.default')" "days"
	assert_equal "$(prop 'delivery_delay_value.default')" "0"
	assert_equal "$(prop 'delivery_delay_unit.default')" "seconds"
	assert_equal "$(prop 'max_message_size_kib.default')" "1024"
	assert_equal "$(prop 'receive_wait_time_seconds.default')" "0"
	assert_equal "$(prop 'encryption.default')" "Enabled"
	assert_equal "$(prop 'encryption_key_type.default')" "sse-sqs"
	assert_equal "$(prop 'data_key_reuse_value.default')" "5"
	assert_equal "$(prop 'data_key_reuse_unit.default')" "minutes"
	assert_equal "$(prop 'send_access.default')" "owner"
	assert_equal "$(prop 'receive_access.default')" "owner"
	assert_equal "$(prop 'redrive_allow.default')" "disabled"
	assert_equal "$(prop 'dlq_enabled.default')" "disabled"
	assert_equal "$(prop 'dlq_max_receives.default')" "10"
}

@test "the numeric limits match the AWS ranges build_context enforces" {
	assert_equal "$(prop 'visibility_timeout_value.minimum')-$(prop 'visibility_timeout_value.maximum')" "0-43200"
	assert_equal "$(prop 'message_retention_value.minimum')-$(prop 'message_retention_value.maximum')" "1-1209600"
	assert_equal "$(prop 'delivery_delay_value.minimum')-$(prop 'delivery_delay_value.maximum')" "0-900"
	assert_equal "$(prop 'max_message_size_kib.minimum')-$(prop 'max_message_size_kib.maximum')" "1-1024"
	assert_equal "$(prop 'receive_wait_time_seconds.minimum')-$(prop 'receive_wait_time_seconds.maximum')" "0-20"
	assert_equal "$(prop 'data_key_reuse_value.minimum')-$(prop 'data_key_reuse_value.maximum')" "1-86400"
	assert_equal "$(prop 'dlq_max_receives.minimum')-$(prop 'dlq_max_receives.maximum')" "1-1000"
}

@test "each unit field offers exactly the units its range allows" {
	units() { prop "$1.oneOf" | jq -c '[.[].const]'; }
	assert_equal "$(units visibility_timeout_unit)" '["seconds","minutes","hours"]'
	assert_equal "$(units message_retention_unit)" '["seconds","minutes","hours","days"]'
	assert_equal "$(units delivery_delay_unit)" '["seconds","minutes"]'
	assert_equal "$(units data_key_reuse_unit)" '["minutes","hours"]'
}

@test "the enum values are the ones the scripts understand" {
	vals() { prop "$1.oneOf" | jq -c '[.[].const]'; }
	assert_equal "$(vals queue_type)" '["standard","fifo"]'
	assert_equal "$(vals encryption_key_type)" '["sse-sqs","sse-kms"]'
	assert_equal "$(vals send_access)" '["owner","principals"]'
	assert_equal "$(vals receive_access)" '["owner","principals"]'
	assert_equal "$(vals redrive_allow)" '["disabled","allow_all","by_queue","deny_all"]'
	assert_equal "$(vals dlq_enabled)" '["disabled","enabled"]'
}

@test "the service exports the queue url and arn and nothing secret" {
	assert_equal "$(prop 'queue_url.export')" "true"
	assert_equal "$(prop 'queue_arn.export')" "true"
	run jq -e '[.attributes.schema.properties[] | select(.export | type == "object")] | length == 0' "$SPEC"
	[ "$status" -eq 0 ]
}

@test "every control in the form points at a property and every input property has a control" {
	run jq -e '
		.attributes.schema as $s
		| [ $s.uiSchema | .. | objects | select(.type == "Control") | .scope | sub("^#/properties/"; "") ] as $controls
		| ($controls | all(. as $k | $s.properties | has($k)))
		  and (($s.properties | keys) - $controls - ["aws_region","queue_url","queue_arn","queue_name"] == [])
	' "$SPEC"
	[ "$status" -eq 0 ]
}

@test "the conditional fields are shown only when their switch is on" {
	cond() {
		jq -r --arg scope "#/properties/$1" '
			[.attributes.schema.uiSchema | .. | objects | select(.scope? == $scope) | .rule.condition | "\(.scope) \(.schema | tojson)"] | first' "$SPEC"
	}
	assert_equal "$(cond kms_key_arn)" '#/properties/encryption_key_type {"const":"sse-kms"}'
	assert_equal "$(cond data_key_reuse_value)" '#/properties/encryption_key_type {"const":"sse-kms"}'
	assert_equal "$(cond data_key_reuse_unit)" '#/properties/encryption_key_type {"const":"sse-kms"}'
	assert_equal "$(cond send_principals)" '#/properties/send_access {"const":"principals"}'
	assert_equal "$(cond receive_principals)" '#/properties/receive_access {"const":"principals"}'
	assert_equal "$(cond redrive_source_queues)" '#/properties/redrive_allow {"const":"by_queue"}'
	assert_equal "$(cond dlq_arn)" '#/properties/dlq_enabled {"const":"enabled"}'
	assert_equal "$(cond dlq_max_receives)" '#/properties/dlq_enabled {"const":"enabled"}'
	run jq -e '[.attributes.schema.uiSchema | .. | objects | select(has("rule")) | .rule.effect] | all(. == "SHOW")' "$SPEC"
	[ "$status" -eq 0 ]
}

@test "the hidden-when-off string fields accept an empty value" {
	for p in kms_key_arn dlq_arn; do
		pattern=$(prop "$p.pattern")
		[[ "" =~ $pattern ]]
	done
}

@test "the link exports the credentials as secrets and the region as plain" {
	assert_equal "$(jq -r '.attributes.schema.properties.access_key_id.export' "$LINK")" "true"
	assert_equal "$(jq -c '.attributes.schema.properties.secret_access_key.export' "$LINK")" '{"type":"environment_variable","secret":true}'
	assert_equal "$(jq -r '.attributes.schema.properties.aws_region.export' "$LINK")" "true"
	assert_equal "$(jq -c '.attributes.schema.required' "$LINK")" '["access_key_id","secret_access_key"]'
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats sqs/scripts/tests/aws/specs.bats`
Expected: FAIL (the template specs have no such properties).

- [ ] **Step 3: Write the service spec**

Create `sqs/specs/service-spec.json.tpl`:

```json
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
          "default": "disabled",
          "oneOf": [
            { "const": "disabled", "title": "Disabled" },
            { "const": "allow_all", "title": "Allow all source queues from the same account and region to use this queue as their dead-letter queue" },
            { "const": "by_queue", "title": "By queue: only the source queues you list" },
            { "const": "deny_all", "title": "Deny all source queues" }
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
```

- [ ] **Step 4: Write the link spec and `values.yaml`**

`sqs/specs/links/connect.json.tpl`:

```json
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
```

`sqs/values.yaml`:

```yaml
# Static configuration for the service workflows (not shown in the nullplatform UI).
# Read it in scripts from the file at $VALUES.

# Local testing only: AWS profile the scripts use when no IAM provider publishes a role
# (run `aws sso login --profile <name>` first). Leave unset in production.
# aws_profile: "my-sso-profile"
```

- [ ] **Step 5: Run to verify it passes**

Run: `bats sqs/scripts/tests/aws/specs.bats && jq . sqs/specs/service-spec.json.tpl sqs/specs/links/connect.json.tpl > /dev/null && echo VALID`
Expected: all PASS, then `VALID`.

- [ ] **Step 6: Commit**

```bash
git add -A sqs
git commit -m "$(cat <<'EOF'
feat(sqs): add the service and link specs with the queue form

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: The IAM requirements module and the CI validation job

**Files:**
- Create: `sqs/specs/requirements/aws/versions.tf`, `providers.tf`, `variables.tf`, `locals.tf`, `data.tf`, `main.tf`, `outputs.tf`, `terraform.tfvars.example`
- Modify: `.github/workflows/tests.yml`

**Interfaces:**
- Consumes: the resources the scripts and modules touch: SQS queues named `np-*`, IAM users named `np-*`, the shared state bucket under `services/sqs/*`, KMS keys.
- Produces: `permissions_role_arn` (to publish under selector `sqs`), `permissions_role_name`, `permissions_role_id`.

- [ ] **Step 1: Write the module**

`sqs/specs/requirements/aws/versions.tf`:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
```

`sqs/specs/requirements/aws/providers.tf`:

```hcl
provider "aws" {
  region = var.region
}
```

`sqs/specs/requirements/aws/data.tf`:

```hcl
data "aws_caller_identity" "current" {}
```

`sqs/specs/requirements/aws/variables.tf`:

```hcl
variable "region" {
  description = "Region the IAM resources are created through. IAM is global; this only selects the API endpoint."
  type        = string
  default     = "us-east-1"
}

variable "agent_role_arn" {
  description = "ARN of the primary nullplatform agent IRSA role allowed to assume this permissions role via sts:AssumeRole, and always a trusted principal of the role's trust policy. Defaults (when empty) to the conventional agent role for the cluster: arn:aws:iam::<account>:role/nullplatform-<cluster_name>-agent-role."
  type        = string
  default     = ""

  validation {
    condition     = var.agent_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/.+", var.agent_role_arn))
    error_message = "agent_role_arn must be empty (to use the derived default) or match arn:aws:iam::<account-id>:role/<role-name>"
  }
}

variable "additional_agent_role_arns" {
  description = "Extra IAM role ARNs allowed to assume this permissions role, appended to agent_role_arn in the trust policy. Defaults to none."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.additional_agent_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/.+", arn))])
    error_message = "each additional_agent_role_arns entry must match arn:aws:iam::<account-id>:role/<role-name>"
  }
}

variable "cluster_name" {
  description = "Name of the cluster the nullplatform agent runs in. Used only to derive default names for the permissions role, the policy prefix and the agent role ARN."
  type        = string
}

variable "role_name" {
  description = "Override for the SQS permissions IAM role name. Defaults to nullplatform_{cluster_name}_sqs_role."
  type        = string
  default     = ""
}

variable "policies_name_prefix" {
  description = "Override for the IAM policy name prefix. Defaults to nullplatform_{cluster_name}."
  type        = string
  default     = ""
}

variable "resource_name_prefix" {
  description = "Prefix of the queues and IAM users this service manages. The permissions are scoped to resources matching it, so the agent cannot reach queues or users created outside nullplatform."
  type        = string
  default     = "np-"
}

variable "kms_key_arns" {
  description = "KMS keys the agent may use to create SSE-KMS queues (kms:DescribeKey, kms:GenerateDataKey, kms:Decrypt). Defaults to every key; restrict it to the keys your teams use."
  type        = list(string)
  default     = ["*"]
}

variable "iam_create_role" {
  description = "Whether to create the permissions role and its policies. When false, the module produces no resources."
  type        = bool
  default     = true
}

variable "iam_resource_tags_json" {
  description = "Tags to apply to IAM resources created by this module."
  type        = map(string)
  default     = {}
}

variable "state_bucket_name" {
  description = "Name of the existing S3 bucket holding the tofu state for every SQS service. The agent receives it as SQS_S3_STATE_BUCKET; this grants the permissions role access to the services/sqs/ prefix of it."
  type        = string
}
```

`sqs/specs/requirements/aws/locals.tf`:

```hcl
locals {
  iam_module_name = "requirements-sqs"

  iam_create = var.iam_create_role

  role_name            = var.role_name != "" ? var.role_name : "nullplatform_${var.cluster_name}_sqs_role"
  policies_name_prefix = var.policies_name_prefix != "" ? var.policies_name_prefix : "nullplatform_${var.cluster_name}"

  account_id = data.aws_caller_identity.current.account_id

  agent_role_arn = var.agent_role_arn != "" ? var.agent_role_arn : "arn:aws:iam::${local.account_id}:role/nullplatform-${var.cluster_name}-agent-role"

  iam_default_tags = merge(var.iam_resource_tags_json, {
    ManagedBy = "nullplatform-custom-scope-role"
    Module    = local.iam_module_name
  })

  policy_documents = {
    queues = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ManageQueues"
          Effect   = "Allow"
          Action   = ["sqs:*"]
          Resource = "arn:aws:sqs:*:${local.account_id}:${var.resource_name_prefix}*"
        },
        {
          Sid      = "AccountLevelReads"
          Effect   = "Allow"
          Action   = ["sqs:ListQueues"]
          Resource = "*"
        },
      ]
    })

    link_users = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid    = "ManageLinkUsers"
        Effect = "Allow"
        Action = [
          "iam:CreateUser",
          "iam:DeleteUser",
          "iam:GetUser",
          "iam:TagUser",
          "iam:UntagUser",
          "iam:ListUserTags",
          "iam:PutUserPolicy",
          "iam:GetUserPolicy",
          "iam:DeleteUserPolicy",
          "iam:ListUserPolicies",
          "iam:ListAttachedUserPolicies",
          "iam:ListGroupsForUser",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:ListAccessKeys",
        ]
        Resource = "arn:aws:iam::${local.account_id}:user/${var.resource_name_prefix}*"
      }]
    })

    kms = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid      = "UseQueueKeys"
        Effect   = "Allow"
        Action   = ["kms:DescribeKey", "kms:GenerateDataKey", "kms:Decrypt"]
        Resource = var.kms_key_arns
      }]
    })

    state = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "StateBucketLocation"
          Effect   = "Allow"
          Action   = ["s3:GetBucketLocation"]
          Resource = "arn:aws:s3:::${var.state_bucket_name}"
        },
        {
          Sid      = "ListStatePrefix"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:ListBucketVersions"]
          Resource = "arn:aws:s3:::${var.state_bucket_name}"
          Condition = {
            StringLike = { "s3:prefix" = ["services/sqs/*"] }
          }
        },
        {
          Sid    = "ManageStateObjects"
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:GetObjectVersion",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:DeleteObjectVersion",
          ]
          Resource = "arn:aws:s3:::${var.state_bucket_name}/services/sqs/*"
        },
      ]
    })
  }
}
```

`sqs/specs/requirements/aws/main.tf`:

```hcl
resource "aws_iam_role" "nullplatform_sqs" {
  count = local.iam_create ? 1 : 0

  name        = local.role_name
  description = "Permissions role assumed by the nullplatform agent role for the aws-sqs service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = concat([local.agent_role_arn], var.additional_agent_role_arns) }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.iam_default_tags
}

resource "aws_iam_policy" "this" {
  for_each = local.iam_create ? local.policy_documents : {}

  name        = "${local.policies_name_prefix}_sqs_${each.key}_policy"
  description = "${each.key} permissions for the nullplatform aws-sqs service"
  policy      = each.value

  tags = local.iam_default_tags
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = aws_iam_policy.this

  role       = aws_iam_role.nullplatform_sqs[0].name
  policy_arn = each.value.arn
}
```

`sqs/specs/requirements/aws/outputs.tf`:

```hcl
output "permissions_role_arn" {
  description = "ARN of the role the agent assumes to operate this service. Publish it to the nullplatform AWS IAM provider under selector \"sqs\"."
  value       = local.iam_create ? aws_iam_role.nullplatform_sqs[0].arn : ""
}

output "permissions_role_name" {
  description = "Name of the permissions role"
  value       = local.iam_create ? aws_iam_role.nullplatform_sqs[0].name : ""
}

output "permissions_role_id" {
  description = "ID of the permissions role"
  value       = local.iam_create ? aws_iam_role.nullplatform_sqs[0].id : ""
}
```

`sqs/specs/requirements/aws/terraform.tfvars.example`:

```hcl
# Copy to terraform.tfvars and fill in. Optional variables are commented out at their defaults.

cluster_name      = "<nullplatform agent cluster>"
state_bucket_name = "<existing S3 bucket for the tofu state>"

# region                     = "us-east-1"
# agent_role_arn             = ""
# additional_agent_role_arns = []
# role_name                  = ""
# policies_name_prefix       = ""
# resource_name_prefix       = "np-"
# kms_key_arns               = ["*"]
# iam_create_role            = true
# iam_resource_tags_json     = {}
```

- [ ] **Step 2: Format and validate**

Run:
```bash
tofu fmt -check -recursive sqs/specs/requirements/aws
tofu -chdir=sqs/specs/requirements/aws init -backend=false -input=false
tofu -chdir=sqs/specs/requirements/aws validate
```
Expected: `fmt` prints nothing; `Success! The configuration is valid.`

- [ ] **Step 3: Add the validation job to CI**

Append this job to `.github/workflows/tests.yml` (under `jobs:`):

```yaml
  tofu-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: opentofu/setup-opentofu@v1
        with:
          tofu_version: 1.12.6
      - run: |
          set -e
          for dir in sqs/deployment sqs/permissions sqs/specs/requirements/aws; do
            tofu fmt -check "$dir"
            tofu -chdir="$dir" init -backend=false -input=false
            tofu -chdir="$dir" validate
          done
```

- [ ] **Step 4: Commit**

```bash
git add -A sqs .github/workflows/tests.yml
git commit -m "$(cat <<'EOF'
feat(sqs): add the iam role the agent assumes and validate the modules in ci

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Service registration modules

**Files:**
- Create: `nullplatform/main.tf`, `variables.tf`, `versions.tf`, `outputs.tf`, `terraform.tfvars.example`
- Create: `nullplatform-bindings/main.tf`, `variables.tf`, `versions.tf`, `data.tf`, `terraform.tfvars.example`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the service spec (Task 9) read from a local path.
- Produces: output `service_specification_slug`, read by `nullplatform-bindings/` through the local remote state.

Unlike valkey's copies, no organization NRN, API key or home-directory path is committed: all of them are variables, and `*.tfvars` are git-ignored.

- [ ] **Step 1: Ignore the files that carry secrets**

Append to `.gitignore`:

```
*.tfvars
*.tfvars.json
.terraform.lock.hcl
```

Then confirm the examples are not ignored: `git check-ignore nullplatform/terraform.tfvars.example || echo "example is tracked"` → `example is tracked`.

- [ ] **Step 2: Write `nullplatform/`**

`nullplatform/versions.tf`:

```hcl
terraform {
  required_providers {
    nullplatform = {
      source  = "nullplatform/nullplatform"
      version = ">= 0.0.104"
    }
  }
}
```

`nullplatform/variables.tf`:

```hcl
variable "np_api_key" {
  type      = string
  sensitive = true
}

variable "nrn" {
  type        = string
  description = "NRN the service specification is registered under, for example organization=<id>:account=<id>:namespace=<id>"
}

variable "local_specs_path" {
  type        = string
  description = "Absolute path of this repository's sqs/ directory, read straight from disk (git_provider = local)"
}
```

`nullplatform/main.tf`:

```hcl
provider "nullplatform" {
  api_key = var.np_api_key
}

module "service_definition_aws_sqs" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v8.1.0"

  nrn          = var.nrn
  service_name = "AWS SQS"
  service_path = "sqs"

  git_provider      = "local"
  local_specs_path  = var.local_specs_path
  repository_branch = "" # ignored in local mode, but the variable is required
}
```

`nullplatform/outputs.tf`:

```hcl
output "service_specification_slug" {
  value = module.service_definition_aws_sqs.service_specification_slug
}

output "service_specification_id" {
  value = module.service_definition_aws_sqs.service_specification_id
}
```

`nullplatform/terraform.tfvars.example`:

```hcl
np_api_key       = "<nullplatform API key>"
nrn              = "organization=<id>:account=<id>:namespace=<id>"
local_specs_path = "/absolute/path/to/services-aws-sqs/sqs"
```

- [ ] **Step 3: Write `nullplatform-bindings/`**

`nullplatform-bindings/versions.tf`: identical to `nullplatform/versions.tf`.

`nullplatform-bindings/data.tf`:

```hcl
data "terraform_remote_state" "nullplatform" {
  backend = "local"
  config = {
    path = "../nullplatform/terraform.tfstate"
  }
}
```

`nullplatform-bindings/variables.tf`:

```hcl
variable "np_api_key" {
  type      = string
  sensitive = true
}

variable "nrn" {
  type        = string
  description = "Same NRN the service specification was registered under"
}

variable "agent_tags_selectors" {
  type        = map(string)
  description = "Tags the notification channel selects. They must match the tags the agent registers with, or notifications are created but never routed. A local `np package run` agent carries local=<your user>."
}

variable "repository_name" {
  type        = string
  default     = "services-aws-sqs"
  description = "Name of the folder (or symlink) under base_clone_path that holds this repository"
}
```

`nullplatform-bindings/main.tf`:

```hcl
provider "nullplatform" {
  api_key = var.np_api_key
}

module "service_definition_agent_association_aws_sqs" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v8.1.0"

  nrn            = var.nrn
  api_key        = var.np_api_key
  tags_selectors = var.agent_tags_selectors

  service_specification_slug   = data.terraform_remote_state.nullplatform.outputs.service_specification_slug
  repository_service_spec_repo = var.repository_name
  service_path                 = "sqs"
  base_clone_path              = pathexpand("~/.np")
}
```

`nullplatform-bindings/terraform.tfvars.example`:

```hcl
np_api_key           = "<nullplatform API key>"
nrn                  = "organization=<id>:account=<id>:namespace=<id>"
agent_tags_selectors = { local = "<your user>" }
```

- [ ] **Step 4: Validate both**

Run:
```bash
tofu fmt -check -recursive nullplatform nullplatform-bindings
tofu -chdir=nullplatform init -backend=false -input=false && tofu -chdir=nullplatform validate
tofu -chdir=nullplatform-bindings init -backend=false -input=false && tofu -chdir=nullplatform-bindings validate
```
Expected: `Success! The configuration is valid.` twice. (`init` downloads the nullplatform provider and the two modules from GitHub; it needs network.)

- [ ] **Step 5: Commit**

```bash
git add -A nullplatform nullplatform-bindings .gitignore
git commit -m "$(cat <<'EOF'
feat(sqs): add the modules that register the service and its agent channel

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: README

**Files:**
- Modify: `README.md` (replace the template text; keep its "Run locally as a package", "CI", "Image tags" and "Publishing" sections, updated to `sqs`)

**Interfaces:**
- Consumes: everything above. Produces the documentation of the service.

- [ ] **Step 1: Replace the top of the README**

Keep the existing sections from `## Run locally as a package` to the end (they already say `sqs` after Task 1). Replace everything above them (title, "Start here", "Layout") with:

````markdown
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
├── deployment/                    # the queue, its policy and redrive policies
├── permissions/                   # link: IAM user, policy and access key
├── scripts/aws/                   # sqs_lib, context building, tofu execution, outputs
│   └── tests/aws/                 # BATS unit tests
├── utils/                         # assume role helpers
├── entrypoint/                    # action routing
├── workflows/                     # one file per action
└── values.yaml                    # static config, not exposed in the UI
nullplatform/                      # registers the service definition
nullplatform-bindings/             # routes notifications to an agent
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

**3b. Region.** The region comes from the account configuration (`aws.region`) or the account provider.

**4. Register the service.** Apply `nullplatform/` (service definition) and then `nullplatform-bindings/` (agent channel). Copy each `terraform.tfvars.example` to `terraform.tfvars` first; `*.tfvars` are git-ignored.

## How it works

Before any AWS call, each workflow assumes the permissions role published in the IAM provider under the selector `sqs`, and every later step runs on the temporary credentials it returns. When the provider publishes no role for that selector, the agent keeps its own credentials, which is what makes local testing work.

`build_context` turns the form into a `terraform.tfvars.json`. Every "value + unit" pair is converted to seconds, and every range is checked there with a message that names the field, because the form schema cannot validate a value against a unit.

The queue is named `np-<name>`, or `np-<name>.fifo` for FIFO, and the name is saved in the service attributes (`queue_name`) the first time. Renaming the service or editing the form never renames or recreates the queue. The `np-` prefix is what scopes the permissions role to queues created by nullplatform. SQS names are unique per account and region, so a second queue with the same name fails with `QueueAlreadyExists`.

Each link user is named `np-<link slug>-<first 5 characters of the link id>-user`. Its access key is generated by Terraform, stored only in the link's state and attributes, and delivered to the application as a secret environment variable.

## Connecting

nullplatform names each exported variable `<LINK SLUG>_<ATTRIBUTE>` in upper case, with hyphens removed. For a link whose slug is `orders-api`:

| Variable | From | |
| :---- | :---- | :---- |
| `ORDERSAPI_QUEUE_URL` | service | Queue URL |
| `ORDERSAPI_QUEUE_ARN` | service | Queue ARN |
| `ORDERSAPI_AWS_REGION` | link | Region of the queue |
| `ORDERSAPI_ACCESS_KEY_ID` | link | Access key of the link's IAM user |
| `ORDERSAPI_SECRET_ACCESS_KEY` | link | secret |

Map them to the standard names your SDK reads (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`) and send to the queue URL.

An SSE-KMS queue also needs the key policy of your key to allow the link user (`kms:GenerateDataKey`, `kms:Decrypt`).

## Local testing

Set `aws_profile` in `values.yaml`, run `aws sso login --profile <name>`, and start the agent with `np package run` (below). With no IAM provider configured, the service runs on that profile's credentials.

Unit tests run with [bats-core](https://github.com/bats-core/bats-core):

```bash
bats sqs/scripts/tests/aws/ sqs/utils/tests/
```

````

- [ ] **Step 2: Check the README against the code**

Run:
```bash
grep -n "my-service\|valkey\|Valkey" README.md
grep -c "SQS_S3_STATE_BUCKET" README.md
```
Expected: the first prints nothing; the second prints `2` or more.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(sqs): document the service, its installation and how applications connect

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Run it for real (done with the user)

This task needs an AWS session, a nullplatform API key and an application, so it is run with Patrick, step by step. It is also where the two open questions in the spec get answered: whether the form honors `rule`, and whether it renders the `tags` list.

**Files:**
- Modify only if the checks below force a fallback: `sqs/specs/service-spec.json.tpl`, `sqs/scripts/aws/build_context` (tags), `sqs/scripts/tests/aws/specs.bats`

- [ ] **Step 1: Local checks that need no cloud**

Run: `bats sqs/scripts/tests/aws/ sqs/utils/tests/ && echo ALL-PASS`
Expected: `ALL-PASS`. Optional if installed: `brew install shellcheck && shellcheck sqs/scripts/aws/* sqs/entrypoint/* sqs/utils/assume_role* && echo CLEAN`.

- [ ] **Step 2: Create the state bucket and the permissions role in the test account**

With `aws sso login --profile <profile>` active:
```bash
aws s3api create-bucket --bucket <state bucket> --region <region> --create-bucket-configuration LocationConstraint=<region>   # omit the configuration for us-east-1
aws s3api put-bucket-versioning --bucket <state bucket> --versioning-configuration Status=Enabled
cd sqs/specs/requirements/aws && cp terraform.tfvars.example terraform.tfvars   # fill it in
tofu init && tofu apply
```
Expected: `permissions_role_arn` output. For a first local run the role does not have to be published: with no IAM provider entry the scripts use the profile's own credentials.

- [ ] **Step 3: Register the service definition and the channel**

```bash
cd nullplatform && cp terraform.tfvars.example terraform.tfvars   # fill it in
tofu init && tofu apply
cd ../nullplatform-bindings && cp terraform.tfvars.example terraform.tfvars   # fill it in
tofu init && tofu apply
```
Expected: the service appears in the nullplatform catalog as **AWS SQS**. Open the create form and check the two open questions:
1. Pick **SSE-KMS**: `KMS key ARN`, `Data key reuse period` and its unit appear; back to SSE-SQS they disappear. Repeat with Send/Receive `principals`, Redrive `By queue`, Dead-letter `Enabled`.
2. Add two tags with the **Tags** control.

If (1) fails (all fields always visible), keep the `rule`s (harmless) and note it in the README; `build_context` already ignores the fields that do not apply. If (2) fails, change `tags` in `service-spec.json.tpl` to `{"type":"string","title":"Tags","description":"key=value pairs separated by commas"}`, update the `tags` assertion in `specs.bats` if any, and re-run `bats sqs/scripts/tests/aws/specs.bats` (`sqs_user_tags_json` already accepts the string form).

- [ ] **Step 4: Start the agent locally and create a Standard queue**

```bash
export NP_API_KEY=...
export SQS_S3_STATE_BUCKET=<state bucket>
eval "$(aws configure export-credentials --format env)"
np package run --log-level DEBUG
```
(`mise.toml` forwards the shell environment to the worker; the binding's `agent_tags_selectors` must equal `local=<your user>`.) Create an AWS SQS service in an application, name `smoke`, defaults everywhere.
Expected: the action succeeds; `aws sqs list-queues --queue-name-prefix np-smoke` lists `np-smoke`; `aws sqs get-queue-attributes --queue-url <url> --attribute-names All` shows `SqsManagedSseEnabled: true`, `VisibilityTimeout: 30`, `MessageRetentionPeriod: 345600`; the service attributes show `queue_url` and `queue_arn`; `aws s3 ls s3://<state bucket>/services/sqs/ --recursive` shows the state key.

- [ ] **Step 5: Exercise the other shapes**

For each, create (or update) and check with `get-queue-attributes`:
1. FIFO queue named `smoke-fifo` → AWS name `np-smoke-fifo.fifo`, `FifoQueue: true`.
2. Update `smoke`: visibility `2 hours`, retention `90 minutes`, delay `5 minutes`, size `256`, wait `20` → `7200`, `5400`, `300`, `262144`, `20`; the queue ARN is unchanged (no replacement). Try values outside the range from the UI and confirm the action fails with the `ERROR:` message.
3. SSE-KMS queue with a real key ARN, then with the key's alias ARN, reuse `1 hours` → `KmsMasterKeyId` set, `KmsDataKeyReusePeriodSeconds: 3600`. Switch it back to SSE-SQS → `SqsManagedSseEnabled: true`.
4. Send principals: your own account ID → `aws sqs get-queue-attributes --attribute-names Policy` shows the `PrincipalsSend` statement.
5. A dead-letter pair: queue `smoke-dlq` with redrive allow `allow_all`; `smoke` with dead-letter `Enabled` pointing at its ARN, max receives `3` → `RedrivePolicy` and `RedriveAllowPolicy` present.

- [ ] **Step 6: Link and use the credentials**

Link the application to `smoke`. Expected: an IAM user `np-<link>-<5>-user` exists with the inline policy; the link attributes hold the key; the application receives `<LINKSLUG>_ACCESS_KEY_ID`, `<LINKSLUG>_SECRET_ACCESS_KEY`, `<LINKSLUG>_AWS_REGION`, `<LINKSLUG>_QUEUE_URL`.
Then, with the key from the link, `AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… aws sqs send-message --queue-url <url> --message-body hi --region <region>` and `receive-message` succeed. Repeat the link on the SSE-KMS queue (alias ARN) and confirm send and receive still work — this is Review Focus item 5.

- [ ] **Step 7: Tear down**

Delete the link (the IAM user and key are removed), then delete each queue service. Expected: `aws sqs list-queues --queue-name-prefix np-smoke` is empty and `aws s3 ls s3://<state bucket>/services/sqs/` no longer lists the deleted services' prefixes.

- [ ] **Step 8: Commit any fallback and push the branch**

If Step 3 forced a change:
```bash
git add -A sqs
git commit -m "$(cat <<'EOF'
fix(sqs): fall back to a text field for the tags in the form

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```
Pushing the branch and opening the PR are for Patrick to ask for; CI then builds the image (`beta.yml`), runs shellcheck, trivy and the `tests` workflow, which this machine cannot.
