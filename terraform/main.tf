terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# 1. Enable Required Cloud APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com"
  ])
  service            = each.value
  disable_on_destroy = false
}

# 2. Artifact Registry for Container Storage
resource "google_artifact_registry_repository" "repo" {
  depends_on    = [google_project_service.apis]
  location      = var.region
  repository_id = var.repository_name
  description   = "Docker storage for build-info microservice"
  format        = "DOCKER"
}

# 3. Dedicated Least-Privilege Runtime Service Account for Cloud Run
resource "google_service_account" "app_sa" {
  account_id   = "sa-build-info-runner"
  display_name = "Cloud Run Runtime Execution SA"
}

# 4. IAM Bindings for Cloud Build Deployment
data "google_project" "project" {}

resource "google_project_iam_member" "cloudbuild_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

resource "google_service_account_iam_member" "cloudbuild_actas" {
  service_account_id = google_service_account.app_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

# 5. Cloud Run Service Definition (v2 API)
resource "google_cloud_run_v2_service" "service" {
  name     = var.service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.app_sa.email

    scaling {
      min_instance_count = 0 # Scale-to-zero when idle to keep cost at $0
      max_instance_count = 3 # Hard limit against traffic surges
    }

    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello:latest"

      resources {
        limits = {
          cpu    = "1000m"
          memory = "256Mi"
        }
        cpu_idle = true
      }

      ports {
        container_port = 8080
      }

      startup_probe {
        http_get {
          path = "/healthz"
          port = 8080
        }
        initial_delay_seconds = 0
        period_seconds        = 3
        failure_threshold     = 3
      }

      liveness_probe {
        http_get {
          path = "/healthz"
          port = 8080
        }
        period_seconds    = 10
        failure_threshold = 3
      }
    }
  }

  depends_on = [google_project_service.apis]
}

# 6. Public Access Policy
resource "google_cloud_run_service_iam_member" "public_access" {
  location = google_cloud_run_v2_service.service.location
  service  = google_cloud_run_v2_service.service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
