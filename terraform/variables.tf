variable "project_id" {
  type        = string
  description = "Target Google Cloud Project ID"
}

variable "region" {
  type        = string
  description = "Primary Google Cloud Region"
  default     = "us-central1"
}

variable "repository_name" {
  type        = string
  description = "Artifact Registry Docker repository ID"
  default     = "build-info-repo"
}

variable "service_name" {
  type        = string
  description = "Cloud Run service identifier"
  default     = "build-info-api"
}
