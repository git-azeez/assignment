# ==============================================================================
# File: terraform/variables.tf
# Purpose: Input variable schemas for the banking infrastructure stack
# ==============================================================================

variable "project_id" {
  type        = string
  description = "The target Google Cloud Project ID (e.g., moz-poc)"
}

variable "region" {
  type        = string
  description = "The primary Google Cloud region for compute and storage"
  default     = "us-central1"
}

variable "repository_name" {
  type        = string
  description = "Artifact Registry Docker repository name"
  default     = "build-info-repo"
}

variable "service_name" {
  type        = string
  description = "Cloud Run service identifier"
  default     = "build-info-api"
}

variable "github_owner" {
  type        = string
  description = "Your personal GitHub username or organization name"
  default     = "git-azeez"
}

variable "github_repo_name" {
  type        = string
  description = "The GitHub repository name"
  default     = "assignment"
}

variable "approver_email" {
  type        = string
  description = "The email of the engineer or manager authorized to approve builds"
}