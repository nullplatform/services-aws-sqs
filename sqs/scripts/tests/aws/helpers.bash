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
	version) printf 'OpenTofu v1.12.6\non test\n' ;;
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
