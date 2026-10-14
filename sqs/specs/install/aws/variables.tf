variable "nrn" {
  description = "NRN the service definition is registered under, for example organization=<org>:account=<account>:namespace=<namespace>."
  type        = string
}

variable "tags_selectors" {
  description = "Tags selecting the agents that receive this service's actions. They must match the tags the agent registers with, or actions are created but never routed."
  type        = map(string)
}

variable "service_name" {
  description = "Display name of the service in nullplatform."
  type        = string
  default     = "AWS SQS"
}

variable "repository_org" {
  description = "GitHub organization owning this repository."
  type        = string
  default     = "nullplatform"
}

variable "repository_name" {
  description = "Name of this repository. Also the directory the agent clones it into, which the entrypoint path is built from."
  type        = string
  default     = "services-aws-sqs"
}

variable "repository_branch" {
  description = "Pinned git ref of this repository the specs are read from: a release tag or a commit SHA, never a moving branch."
  type        = string

  validation {
    condition     = var.repository_branch != "" && !contains(["main", "master", "head", "latest"], lower(var.repository_branch))
    error_message = "repository_branch must be a pinned ref, not empty and not a moving branch."
  }
}

variable "repository_ref_type" {
  description = "Namespace repository_branch lives in: \"tags\" for a tag, \"heads\" for a branch, \"\" for a raw commit SHA."
  type        = string
  default     = "tags"
}

variable "repository_token" {
  description = "Access token for a private repository. Unnecessary for a public one."
  type        = string
  default     = null
  sensitive   = true
}

variable "base_clone_path" {
  description = "Directory the agent clones service repositories into."
  type        = string
  default     = "/home/agent/.np"
}
