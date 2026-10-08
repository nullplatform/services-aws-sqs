terraform {
  required_providers {
    nullplatform = {
      source  = "nullplatform/nullplatform"
      version = ">= 0.0.104, < 0.1.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}
