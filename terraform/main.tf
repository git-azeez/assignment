# ==============================================================================
# File: terraform/main.tf
# Purpose: Enterprise banking microservice infrastructure with approval gate
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }

  # ----------------------------------------------------------------------------
  # Remote State Storage in Google Cloud Storage (The Shared Lockbox)
  # ----------------------------------------------------------------------------
  backend "gcs" {
    bucket = "az-assignment"
    prefix = "terraform/state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ------------------------------------------------------------------------------
# 1. Project Information Lookup
# ------------------------------------------------------------------------------
data "google_project" "project" {}

# ------------------------------------------------------------------------------
# 2. Enable Required Google Cloud Service APIs
# ------------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com"
  ])
  service            = each.value
  disable_on_destroy = false
}

# ------------------------------------------------------------------------------
# 3. Artifact Registry (Secure Container Locker)
# ------------------------------------------------------------------------------
resource "google_artifact_registry_repository" "repo" {
  depends_on    = [google_project_service.apis]
  location      = var.region
  repository_id = var.repository_name
  description   = "Docker storage for banking build-info microservice"
  format        = "DOCKER"
}

# ------------------------------------------------------------------------------
# 4. Runtime Service Account for Cloud Run (The Bank Teller)
# ------------------------------------------------------------------------------
resource "google_service_account" "app_sa" {
  account_id   = "sa-build-info-runner"
  display_name = "Cloud Run Runtime Execution SA"
}

# ------------------------------------------------------------------------------
# 5. Dedicated CI/CD Service Account for Cloud Build (Required for Approvals)
# ------------------------------------------------------------------------------
resource "google_service_account" "cloudbuild_sa" {
  account_id   = "sa-cloudbuild-runner"
  display_name = "Dedicated Cloud Build CI/CD Service Account"
}

# Grant Cloud Build SA permission to build and log
resource "google_project_iam_member" "cloudbuild_builder" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}

# Grant Cloud Build SA permission to push images into Artifact Registry
resource "google_artifact_registry_repository_iam_member" "cloudbuild_writer" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.repo.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}

# Grant Cloud Build SA permission to deploy revisions to Cloud Run
resource "google_project_iam_member" "cloudbuild_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}

# Grant Cloud Build SA permission to assign the runtime SA to Cloud Run
resource "google_service_account_iam_member" "cloudbuild_actas" {
  service_account_id = google_service_account.app_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}

# Designated Human Approver Role
resource "google_project_iam_member" "human_approver" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.approver"
  member  = "user:${var.approver_email}"
}

# ------------------------------------------------------------------------------
# 6. Cloud Run Service (v2 Serverless Container)
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "service" {
  name     = var.service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.app_sa.email

    scaling {
      min_instance_count = 0
      max_instance_count = 3
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

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version
    ]
  }

  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------------------
# 7. Ingress Access Policy (Complies with Organization Security Policies)
# ------------------------------------------------------------------------------
resource "google_cloud_run_service_iam_member" "invoker_access" {
  location = google_cloud_run_v2_service.service.location
  service  = google_cloud_run_v2_service.service.name
  role     = "roles/run.invoker"
  member   = "user:${var.approver_email}"
}

# ------------------------------------------------------------------------------
# 8. Cloud Build Trigger with Mandatory Human Approval Gate (1st Gen)
# ------------------------------------------------------------------------------
resource "google_cloudbuild_trigger" "safe_deploy_trigger" {
  name        = "auto-deploy-on-push-to-main"
  description = "Triggered on main branch push; halts and waits for human approval."
  location    = "global"

  # Explicit Service Account: Mandatory for approval-gated triggers!
  service_account = google_service_account.cloudbuild_sa.id

  # The Safety Stop Sign
  approval_config {
    approval_required = true
  }

  # 1st-Gen GitHub connection block
  github {
    owner = var.github_owner
    name  = var.github_repo_name
    push {
      branch = "^main$"
    }
  }

  filename = "cloudbuild.yaml"

  substitutions = {
    _LOCATION         = var.region
    _REPO_NAME        = var.repository_name
    _SERVICE_NAME     = var.service_name
    _APP_VERSION      = "v1.0.0"
    _ENV_NAME         = "production"
    _RUNTIME_SA_EMAIL = google_service_account.app_sa.email
  }

  depends_on = [
    google_artifact_registry_repository.repo,
    google_project_iam_member.cloudbuild_builder,
    google_artifact_registry_repository_iam_member.cloudbuild_writer,
    google_project_iam_member.cloudbuild_run_admin,
    google_service_account_iam_member.cloudbuild_actas,
    google_project_iam_member.human_approver
  ]
}