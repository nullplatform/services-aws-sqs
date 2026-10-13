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
