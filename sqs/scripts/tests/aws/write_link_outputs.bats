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
