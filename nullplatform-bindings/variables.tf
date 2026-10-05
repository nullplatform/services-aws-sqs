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
