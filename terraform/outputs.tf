output "service_url" {
  description = "Public HTTPS endpoint for the build-info API"
  value       = google_cloud_run_v2_service.service.uri
}

output "artifact_registry_path" {
  description = "Docker push target for Artifact Registry"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repository_name}"
}

output "runtime_service_account" {
  description = "Dedicated runtime service account email"
  value       = google_service_account.app_sa.email
}
