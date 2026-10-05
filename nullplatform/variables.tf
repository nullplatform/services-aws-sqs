variable "np_api_key" {
  type      = string
  sensitive = true
}

variable "nrn" {
  type        = string
  description = "NRN the service specification is registered under, for example organization=<id>:account=<id>:namespace=<id>"
}

variable "local_specs_path" {
  type        = string
  description = "Absolute path of this repository's sqs/ directory, read straight from disk (git_provider = local)"
}
