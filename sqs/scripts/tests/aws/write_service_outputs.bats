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
