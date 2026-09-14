# ==============================================================================
# File: terraform/outputs.tf
# Purpose: Display essential endpoints and identities after provisioning
# ==============================================================================

output "cloud_run_url" {
  description = "Direct public HTTPS URL of the Cloud Run microservice"
  value       = google_cloud_run_v2_service.service.uri
}

output "artifact_registry_path" {
  description = "Docker push target path in Artifact Registry"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repository_name}"
}

output "runtime_service_account" {
  description = "Dedicated runtime service account email"
  value       = google_service_account.app_sa.email
}

output "trigger_id" {
  description = "The unique ID of the Cloud Build approval trigger"
  value       = google_cloudbuild_trigger.safe_deploy_trigger.id
}