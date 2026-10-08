variable "nrn" {
  description = "NRN the service specification is registered under, in organization=<id>:account=<id> form."
  type        = string
}

variable "api_key" {
  description = "nullplatform API key used to register the service and to authenticate the agent notification channel."
  type        = string
  sensitive   = true
}

variable "git_provider" {
  description = "Where the specs are read from: \"github\" reads them from this repository at repository_branch, \"local\" reads them from local_specs_path on disk (local testing)."
  type        = string
  default     = "github"

  validation {
    condition     = contains(["github", "local"], var.git_provider)
    error_message = "git_provider must be \"github\" or \"local\"."
  }
}

variable "local_specs_path" {
  description = "Absolute path of this repository's sqs/ directory. Required when git_provider is \"local\"."
  type        = string
  default     = null

  validation {
    condition     = var.git_provider != "local" || try(var.local_specs_path != "", false)
    error_message = "local_specs_path is required when git_provider is \"local\"."
  }
}

variable "repository_branch" {
  description = "Pinned git ref of this repository the specs are read from. Must be a tag or commit SHA, never a moving branch. Ignored when git_provider is \"local\"."
  type        = string
  default     = ""

  validation {
    condition     = var.git_provider == "local" || (var.repository_branch != "" && !contains(["main", "master", "head", "latest"], lower(var.repository_branch)))
    error_message = "repository_branch must be a pinned ref, not empty and not a moving branch."
  }
}

variable "repository_ref_type" {
  description = "Namespace repository_branch lives in: \"tags\" for a tag, \"heads\" for a branch, \"\" for a raw commit SHA."
  type        = string
  default     = "tags"

  validation {
    condition     = contains(["heads", "tags", ""], var.repository_ref_type)
    error_message = "repository_ref_type must be \"heads\", \"tags\" or \"\"."
  }
}

variable "agent_tags_selectors" {
  description = "Tags selecting which agents receive this service's notifications. They must match the tags the agent registers with, or notifications are created but never routed."
  type        = map(string)
}

variable "repository_org" {
  description = "GitHub organization owning this repository."
  type        = string
  default     = "nullplatform"
}

variable "repository_name" {
  description = "Name of this repository. Also the directory the agent clones it into, which is what the entrypoint path is built from."
  type        = string
  default     = "services-aws-sqs"
}

variable "base_clone_path" {
  description = "Directory the agent clones service repositories into. A local agent reads them from ~/.np."
  type        = string
  default     = "/home/agent/.np"
}

variable "service_name" {
  description = "Display name of the service specification."
  type        = string
  default     = "AWS SQS"
}

variable "service_path" {
  description = "Path to the service directory within this repository."
  type        = string
  default     = "sqs"
}

variable "available_links" {
  description = "Link template file names under specs/links, without the .json.tpl suffix. Not the link slugs."
  type        = list(string)
  default     = ["connect"]
}

variable "repository_token" {
  description = "Access token used to read the specs when the repository is private."
  type        = string
  default     = null
  sensitive   = true
}

variable "extra_visible_to_nrns" {
  description = "Additional NRNs the service specification is visible to, beyond the one it is registered under."
  type        = list(string)
  default     = []
}

variable "dimensions" {
  description = "Dimensions for the service specification, used when the spec template declares none."
  type        = any
  default     = {}
}

variable "channel_description" {
  description = "Description shown for the agent notification channel."
  type        = string
  default     = "AWS SQS service actions"
}
