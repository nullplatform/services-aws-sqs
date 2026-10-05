setup_mocks() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	UTILS_DIR="$(cd "$TEST_DIR/.." && pwd)"
	MOCK_BIN="$BATS_TEST_TMPDIR/bin"
	MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
	mkdir -p "$MOCK_BIN"
	: > "$MOCK_LOG"
	export MOCK_LOG
	export PATH="$MOCK_BIN:$PATH"
	export MOCK_STS_EXIT="${MOCK_STS_EXIT:-0}"
	if [ -z "${MOCK_STS_OUTPUT:-}" ]; then
		MOCK_STS_OUTPUT='{"Credentials":{"AccessKeyId":"ASSUMEDKEY","SecretAccessKey":"assumedsecret","SessionToken":"assumedtoken"}}'
	fi
	if [ -z "${MOCK_NP_PROVIDERS:-}" ]; then
		MOCK_NP_PROVIDERS='{"results":[]}'
	fi
	export MOCK_STS_OUTPUT MOCK_NP_PROVIDERS
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
	unset SQS_ASSUME_ROLE_ARN SQS_ASSUME_ROLE_ARN_DEFAULT SQS_ASSUME_ROLE_SELECTOR
	unset SQS_ASSUME_ROLE_ARN_RESOLVED SERVICE_ID CONTEXT

	cat > "$MOCK_BIN/aws" <<'MOCK'
#!/bin/bash
echo "aws $*" >> "$MOCK_LOG"
case "$*" in
	*"sts assume-role"*)
		if [ "${MOCK_STS_EXIT:-0}" != "0" ]; then
			echo "An error occurred (AccessDenied)" >&2
			exit "$MOCK_STS_EXIT"
		fi
		echo "$MOCK_STS_OUTPUT"
		;;
esac
exit 0
MOCK

	cat > "$MOCK_BIN/np" <<'MOCK'
#!/bin/bash
echo "np $*" >> "$MOCK_LOG"
case "$*" in
	"provider list"*) echo "$MOCK_NP_PROVIDERS" ;;
	*) echo "{}" ;;
esac
exit 0
MOCK

	chmod +x "$MOCK_BIN"/*
}

run_script() {
	local script="$1"
	run bash -c "set -a; source '$UTILS_DIR/$script' >'$BATS_TEST_TMPDIR/stdout' 2>'$BATS_TEST_TMPDIR/stderr'; rc=\$?; env > '$BATS_TEST_TMPDIR/env'; exit \$rc"
	captured_stdout=$(cat "$BATS_TEST_TMPDIR/stdout")
	captured_stderr=$(cat "$BATS_TEST_TMPDIR/stderr")
}

captured() {
	grep "^$1=" "$BATS_TEST_TMPDIR/env" | head -1 | cut -d= -f2-
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
