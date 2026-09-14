# ==============================================================================
# File: terraform/main.tf
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }
  backend "gcs" {
    bucket  = "az-assignment"
    prefix  = "terraform/state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "project" {}

# ------------------------------------------------------------------------------
# 1. Enable Required Google Cloud Services
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 2. Google Artifact Registry (Secure Container Locker)
# ------------------------------------------------------------------------------
resource "google_artifact_registry_repository" "repo" {
  depends_on    = [google_project_service.apis]
  location      = var.region
  repository_id = var.repository_name
  description   = "Docker storage for banking build-info microservice"
  format        = "DOCKER"
}

# ------------------------------------------------------------------------------
# 3. Dedicated Least-Privilege Runtime Service Account for Cloud Run
# ------------------------------------------------------------------------------
resource "google_service_account" "app_sa" {
  account_id   = "sa-build-info-runner"
  display_name = "Cloud Run Runtime Execution SA"
}

# ------------------------------------------------------------------------------
# 4. IAM Permissions for the Cloud Build Factory Worker
# ------------------------------------------------------------------------------
# Allow Cloud Build to manage Cloud Run deployments
resource "google_project_iam_member" "cloudbuild_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

# Allow Cloud Build to act as the runtime service account
resource "google_service_account_iam_member" "cloudbuild_actas" {
  service_account_id = google_service_account.app_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

# Grant the Golden Key (Approver role) to the designated human approver
resource "google_project_iam_member" "human_approver" {
  project = var.project_id
  role    = "roles/cloudbuild.approver"
  member  = "user:${var.approver_email}"
}

# ------------------------------------------------------------------------------
# 5. Cloud Run Service (v2 Serverless Container)
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "service" {
  name     = var.service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.app_sa.email

    scaling {
      min_instance_count = 0 # Scale to zero when idle ($0 cost)
      max_instance_count = 3 # Hard ceiling against traffic spikes
    }

    containers {
      # Standard placeholder image; Cloud Build updates this upon approved commit
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
          path = "/health"
          port = 8080
        }
        initial_delay_seconds = 0
        period_seconds        = 3
        failure_threshold     = 3
      }

      liveness_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        period_seconds    = 10
        failure_threshold = 3
      }
    }
  }

  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------------------
# 6. Public Access Policy (Allow unauthenticated clients to read endpoints)
# ------------------------------------------------------------------------------
resource "google_cloud_run_service_iam_member" "public_access" {
  location = google_cloud_run_v2_service.service.location
  service  = google_cloud_run_v2_service.service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ------------------------------------------------------------------------------
# 7. Cloud Build Trigger with Mandatory Human Approval Gate
# ------------------------------------------------------------------------------
resource "google_cloudbuild_trigger" "safe_deploy_trigger" {
  name        = "auto-deploy-on-push-to-main"
  description = "Triggered on main branch push; halts and waits for human approval."
  location    = "global"

  # The Safety Stop Sign: build stays in PENDING_APPROVAL until approved
  approval_config {
    approval_required = true
  }

  github {
    owner = var.github_owner
    name  = var.github_repo_name
    push {
      branch = "^main$"
    }
  }

  filename = "cloudbuild.yaml"

  substitutions = {
    _LOCATION       = var.region
    _REPO_NAME      = var.repository_name
    _SERVICE_NAME   = var.service_name
    _APP_VERSION    = "v1.0.0"
    _ENV_NAME       = "production"
    _RUNTIME_SA_EMAIL = google_service_account.app_sa.email
  }

  depends_on = [
    google_artifact_registry_repository.repo,
    google_project_iam_member.cloudbuild_run_admin,
    google_service_account_iam_member.cloudbuild_actas,
    google_project_iam_member.human_approver
  ]
}