#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
}

@test "skips assuming a role when no role arn was resolved" {
	run_script assume_role
	[ "$status" -eq 0 ]
	assert_contains "$captured_stdout" "assume_role=skipped"
	assert_equal "$(captured AWS_ACCESS_KEY_ID)" ""
	assert_not_contains "$(cat "$MOCK_LOG")" "aws sts"
}

@test "assumes the resolved role and exports the returned credentials" {
	export SQS_ASSUME_ROLE_ARN_RESOLVED="arn:aws:iam::111122223333:role/sqs"
	export SERVICE_ID="abc123"
	run_script assume_role
	[ "$status" -eq 0 ]
	assert_contains "$captured_stdout" "Role assumed successfully"
	assert_equal "$(captured AWS_ACCESS_KEY_ID)" "ASSUMEDKEY"
	assert_equal "$(captured AWS_SECRET_ACCESS_KEY)" "assumedsecret"
	assert_equal "$(captured AWS_SESSION_TOKEN)" "assumedtoken"
	assert_contains "$(cat "$MOCK_LOG")" "--role-arn arn:aws:iam::111122223333:role/sqs"
	assert_contains "$(cat "$MOCK_LOG")" "np-sqs-abc123"
}

@test "defaults the sts session name to np-sqs-workflow when no service id is set" {
	export SQS_ASSUME_ROLE_ARN_RESOLVED="arn:aws:iam::111122223333:role/sqs"
	run_script assume_role
	[ "$status" -eq 0 ]
	assert_contains "$(cat "$MOCK_LOG")" "np-sqs-workflow"
}

@test "fails and leaves credentials unset when sts assume-role is denied" {
	export SQS_ASSUME_ROLE_ARN_RESOLVED="arn:aws:iam::111122223333:role/sqs"
	export MOCK_STS_EXIT=1
	run_script assume_role
	[ "$status" -eq 1 ]
	assert_contains "$captured_stderr" "sts:AssumeRole failed"
	assert_equal "$(captured AWS_ACCESS_KEY_ID)" ""
}

@test "fails and leaves credentials unset when sts assume-role returns incomplete credentials" {
	export SQS_ASSUME_ROLE_ARN_RESOLVED="arn:aws:iam::111122223333:role/sqs"
	export MOCK_STS_OUTPUT='{"Credentials":{"AccessKeyId":"ASSUMEDKEY","SecretAccessKey":"assumedsecret"}}'
	run_script assume_role
	[ "$status" -eq 1 ]
	assert_contains "$captured_stderr" "incomplete credentials"
	assert_equal "$(captured AWS_ACCESS_KEY_ID)" ""
}
