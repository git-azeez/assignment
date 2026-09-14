Bank-Grade Microservice on Google Cloud Run with Gated CI/CDAn enterprise-ready, zero-trust microservice running on Google Cloud Run (v2), provisioned entirely via Terraform, and continuously delivered through an automated Cloud Build pipeline governed by a mandatory human-approval gate.🏛️ Executive SummaryIn financial systems and regulated enterprise cloud environments, deployments must adhere to three non-negotiable principles:Zero Supply-Chain Risk: Eliminating third-party packages to prevent upstream dependency hijacking and vulnerability exploits (e.g., Log4j-style vectors).Four-Eyes Governance: Enforcing dual-control approval policies so no artifact or configuration reaches production without review by an authorized lead.End-to-End Immutability & Traceability: Baking cryptographic commit hashes (COMMIT_SHA), UTC timestamps, and version tags directly into the container filesystem at build time to prevent drift and provide auditability.This repository provides an end-to-end implementation of this architecture on Google Cloud Platform.🧒 Architecture in Plain English (The Real-World Analogies)The Bank Teller Robot (app.py): Imagine a robot clerk behind bulletproof bank glass. It never accepts unopened packages from strangers (zero third-party dependencies; pure Python standard library). Whenever someone asks for its identification badge (/info), it displays a laminated, tamper-proof ID card showing its exact version, build timestamp, and health status.The Master Blueprint (Terraform): Instead of manually clicking buttons in the Google Cloud Console, we maintain an Infrastructure-as-Code blueprint. Executing terraform apply instructs Google Cloud to construct the robot's room, security permissions, and storage lockers predictably every time.The Cloud Lockbox (GCS Remote Backend): Keeping your blueprint only on a local laptop risks state loss or desynchronization. We store the state file in a version-controlled Google Cloud Storage bucket (az-assignment) with state locking, ensuring all team members operate from the same state.The Inspection Lock (Cloud Build Approval Gate): When code is merged into main, the assembly line does not push directly to production. It sounds a chime, halts execution with a blue Pending approval badge, and waits without consuming compute minutes until an authorized manager turns the approval key.🏗️ System Architecture  [ Git Push / Merge to 'main' ]
                 │
                 ▼
     [ Cloud Build Trigger ]
                 │
                 ▼
       🛑 1. APPROVAL GATE 🛑  <── (Pending approval; consumes 0 build minutes)
                 │
                 ├──► Tech Lead (roles/cloudbuild.builds.approver) reviews & approves
                 │
                 ▼
     [ Dedicated CI/CD Runner ]  <── (sa-cloudbuild-runner: Least Privilege)
                 │
         ┌───────┴───────┐
         ▼               ▼
   [ Step 1: Bake ] [ Step 2: Build ]
   (Git SHA, UTC,   (Alpine Linux,
    Version)         Non-Root UID 10001)
         │               │
         └───────┬───────┘
                 │
                 ▼
     [ Step 3: Push Image ] ────► [ Google Artifact Registry (build-info-repo) ]
                 │
                 ▼
     [ Step 4: Deploy Rev ] ────► [ Google Cloud Run v2 (build-info-api) ]
                                            │
                                            ▼
                                  [ Service Endpoints ]
                                  ├── /info    (Metadata, OWASP Headers)
                                  └── /health  (Liveness & Startup Probes)
🛡️ Security & Hardening ControlsZero Third-Party Dependencies: Built entirely with Python's standard library (http.server, json, os, signal). No pip install, zero external supply-chain CVE vulnerabilities, and a lightweight container image footprint.Least-Privilege Execution:Runs inside Alpine Linux under a dedicated non-root user (UID 10001: appuser).Cloud Run operates under a dedicated runtime service account (sa-build-info-runner).Cloud Build uses a standalone worker identity (sa-cloudbuild-runner) restricted to building images and deploying revisions.OWASP Financial Header Suite: Every HTTP response returns hardened security headers:Strict-Transport-Security: max-age=63072000; includeSubDomains; preloadContent-Security-Policy: default-src 'none'; frame-ancestors 'none'X-Content-Type-Options: nosniffX-Frame-Options: DENYCache-Control: no-store, no-cache, must-revalidate, max-age=0X-XSS-Protection: 1; mode=blockAnti-Banner Grabbing: Web server tokens and underlying interpreter versions are masked (server_version = "", sys_version = "").Distributed Trace Correlation: Ingests Google Cloud's X-Cloud-Trace-Context header to bind HTTP transactions to Cloud Trace and SIEM audit logs.Zero-Downtime Socket Draining: Linux signal traps intercept SIGTERM and SIGINT from Cloud Run orchestrators to allow in-flight connections to drain before teardown.📂 Repository Layout.
├── app.py                  # Hardened, zero-dependency Python microservice
├── Dockerfile              # Non-root container build file (Alpine runtime)
├── cloudbuild.yaml         # CI/CD pipeline definition with metadata baking
├── VERSION                 # Single source of truth for release versions
├── build_info.json         # Local metadata template for development
├── setup.sh                # Automation script for documentation regeneration
└── terraform/
    ├── main.tf             # Core GCP resources, IAM policies, and approval trigger
    ├── variables.tf        # Input variable definitions and schemas
    ├── terraform.tfvars    # Environment-specific configuration values
    └── outputs.tf          # Exported endpoints, service accounts, and trigger IDs
⚙️ Infrastructure as Code (Terraform Details)The infrastructure is defined modularly in /terraform:ResourceTerraform NamePurposeGCS Backendbackend "gcs"Centralized state storage with locking in az-assignmentArtifact Registrygoogle_artifact_registry_repository.repoPrivate OCI image registry (build-info-repo)Cloud Run v2google_cloud_run_v2_service.serviceServerless container host (build-info-api)Runtime Identitygoogle_service_account.app_saExecution identity (sa-build-info-runner)CI/CD Identitygoogle_service_account.cloudbuild_saGated build runner (sa-cloudbuild-runner)Approval Triggergoogle_cloudbuild_trigger.safe_deploy_triggerHalts commits to main until human sign-offIngress Accessgoogle_cloud_run_service_iam_member.invoker_accessAccess enforcement conforming to Org policies🚀 Deployment & Operations GuidePrerequisitesGoogle Cloud SDK (gcloud) authenticated to project moz-poc.Terraform >= 1.5.0.GitHub repository (git-azeez/assignment) connected in the Cloud Build Console (1st-Gen connection).1. Configure Remote State StorageInitialize the state bucket with object versioning:gcloud storage buckets create gs://az-assignment \
    --project="moz-poc" \
    --location="us-central1" \
    --uniform-bucket-level-access

gcloud storage buckets update gs://az-assignment --versioning
2. Deploy Infrastructurecd terraform/

# Initialize provider plugins and backend state
terraform init

# Validate execution plan
terraform plan

# Apply changes to Google Cloud
terraform apply
3. Resource Adoption (If Pre-Existing)If Artifact Registry, Service Accounts, or Cloud Run services were provisioned outside Terraform, import them:terraform import google_artifact_registry_repository.repo projects/moz-poc/locations/us-central1/repositories/build-info-repo
terraform import google_service_account.app_sa projects/moz-poc/serviceAccounts/sa-build-info-runner@moz-poc.iam.gserviceaccount.com
terraform import google_cloud_run_v2_service.service projects/moz-poc/locations/us-central1/services/build-info-api
🧪 Demonstration & Verification RunbookStep 1: Bump Version or Release MessageUpdate the release state in your workspace:cd ~/az

# 1. Bump the release version
echo "v1.1.0" > VERSION

# 2. Update app.py release message (or leave existing)
# Edit RELEASE_MESSAGE in app.py if desired

# 3. Stage and commit
git add VERSION app.py cloudbuild.yaml Dockerfile
git commit -m "feat: release v1.1.0 with fraud detection engine"
git push origin main
Step 2: Approve the BuildOpen the Google Cloud Build Console.Locate the active build marked with the blue Pending approval badge.Review the Git commit SHA, triggering author, and substitutions.Click Approve.Step 3: Verify the Live EndpointsOnce Cloud Build turns green, verify the service response:curl -i https://build-info-api-642275428789.us-central1.run.app/info
Expected Production Output:{
  "application": "build-info-api",
  "version": "v1.1.0",
  "git_commit": "58801f094ade863689536262ce18ef7c3c57dcd8",
  "build_time": "2026-09-14T04:04:51Z",
  "environment": "production",
  "release_message": "Release 1.1.0: Real-time fraud detection engine enabled version 2",
  "status": "healthy",
  "correlation_id": "e75b2646805d72f459b607bd8fa1fd4e"
}
Expected Health Output:curl -i https://build-info-api-642275428789.us-central1.run.app/health
# Returns: HTTP/2 200 OK (Body: "OK\n")
📋 Security & Compliance AlignmentObjectiveTechnical ImplementationCompliance MappingSupply Chain AssuranceZero 3rd-party dependencies in application codebaseSLSA Level 3 / NIST SP 800-161Least Privilege AccessNon-root container (UID 10001) & dedicated runtime SACIS GCP Benchmark v2.0Change Dual-ControlMandatory Cloud Build human approval gate on mainSOC 2 CC8.1 / PCI-DSS v4.0 Req 6Metadata ImmutabilityGit commit SHA and build timestamp baked into /appISO 27001 A.12.1.2State File IntegrityRemote GCS backend with object versioning & lockingHashiCorp Well-Architected FrameworkTransport HardeningEnforced HSTS, strict CSP, and anti-sniff headersOWASP Top 10 API Security