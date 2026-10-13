#!/usr/bin/env bats

load helpers

setup() {
	setup_mocks
	LOCALS="$SERVICE_PATH/specs/requirements/aws/locals.tf"
}

@test "listing the state bucket is not restricted by prefix: HeadBucket and the S3 backend list without the service prefix" {
	run grep -n 's3:prefix' "$LOCALS"
	[ "$status" -ne 0 ]
	assert_contains "$(grep -A3 'ListStateBucket' "$LOCALS")" '"s3:ListBucket"'
}

@test "reading and writing state objects stays under services/sqs/" {
	assert_contains "$(grep -A12 'ManageStateObjects' "$LOCALS")" 'services/sqs/*'
}
