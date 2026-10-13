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
