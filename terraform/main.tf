# ---------------------------------------------------------------------------
# Notas para un proyecto GCP compartido con otros clientes:
#   - Todos los permisos son *_iam_member (aditivos). Nunca *_iam_binding ni
#     *_iam_policy, que reemplazarían los permisos de otros equipos.
#   - Las APIs no se apagan al hacer destroy (disable_on_destroy = false).
#   - dbt solo puede escribir en sus propios datasets.
# ---------------------------------------------------------------------------

locals {
  apis = [
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "cloudscheduler.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "run.googleapis.com",
    "sts.googleapis.com",
  ]

  layers = ["bronze", "silver", "gold"]

  # prod_bronze, prod_silver, ..., ci_gold
  datasets = merge([
    for env, prefix in { prod = var.prod_dataset_prefix, ci = var.ci_dataset_prefix } : {
      for layer in local.layers : "${env}_${layer}" => {
        env        = env
        dataset_id = "${prefix}_${layer}"
      }
    }
  ]...)
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------- BigQuery

resource "google_bigquery_dataset" "dbt" {
  for_each   = local.datasets
  dataset_id = each.value.dataset_id
  location   = var.bq_location
  labels     = { managed_by = "terraform", app = "dbt", env = each.value.env }

  # Los de CI se pueden borrar con contenido; los de prod no
  delete_contents_on_destroy = each.value.env == "ci"

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------- Service accounts

resource "google_service_account" "runner" {
  account_id   = "dbt-runner"
  display_name = "dbt: ejecuta el job diario"
}

resource "google_service_account" "scheduler" {
  account_id   = "dbt-scheduler"
  display_name = "dbt: dispara el job desde Cloud Scheduler"
}

resource "google_service_account" "deployer" {
  account_id   = "dbt-deployer"
  display_name = "dbt: CI y despliegue desde GitHub Actions"
}

# Runner: correr queries, escribir en prod, leer las fuentes
resource "google_project_iam_member" "runner_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.runner.member
}

resource "google_bigquery_dataset_iam_member" "runner_prod_editor" {
  for_each   = { for k, v in local.datasets : k => v if v.env == "prod" }
  dataset_id = google_bigquery_dataset.dbt[each.key].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_service_account.runner.member
}

resource "google_bigquery_dataset_iam_member" "runner_source_viewer" {
  for_each   = toset(var.source_datasets)
  dataset_id = each.value
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.runner.member
}

# Deployer: correr dbt en CI, subir imágenes, actualizar el job
resource "google_project_iam_member" "deployer_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.deployer.member
}

resource "google_bigquery_dataset_iam_member" "deployer_ci_editor" {
  for_each   = { for k, v in local.datasets : k => v if v.env == "ci" }
  dataset_id = google_bigquery_dataset.dbt[each.key].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_service_account.deployer.member
}

resource "google_bigquery_dataset_iam_member" "deployer_source_viewer" {
  for_each   = toset(var.source_datasets)
  dataset_id = each.value
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.deployer.member
}

# Solo lectura de Cloud Run a nivel proyecto, para que gcloud pueda seguir
# las operaciones del despliegue
resource "google_project_iam_member" "deployer_run_viewer" {
  project = var.project_id
  role    = "roles/run.viewer"
  member  = google_service_account.deployer.member
}

# Para poder desplegar un job que corre como dbt-runner
resource "google_service_account_iam_member" "deployer_acts_as_runner" {
  service_account_id = google_service_account.runner.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.deployer.member
}

# ------------------------------------------------------- Artifact Registry

resource "google_artifact_registry_repository" "dbt" {
  repository_id = "dbt"
  location      = var.region
  format        = "DOCKER"
  description   = "Imágenes del job de dbt"

  cleanup_policies {
    id     = "keep-last-10"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_artifact_registry_repository_iam_member" "deployer_writer" {
  location   = google_artifact_registry_repository.dbt.location
  repository = google_artifact_registry_repository.dbt.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.deployer.member
}

# ----------------------------------------------------------- Cloud Run Job

resource "google_cloud_run_v2_job" "dbt" {
  name                = var.job_name
  location            = var.region
  deletion_protection = false

  template {
    task_count = 1

    template {
      service_account = google_service_account.runner.email
      timeout         = "1800s"
      max_retries     = 1

      containers {
        # Imagen de arranque. GitHub Actions la reemplaza en cada despliegue.
        image = "us-docker.pkg.dev/cloudrun/container/job:latest"

        env {
          name  = "GCP_PROJECT"
          value = var.project_id
        }
        env {
          name  = "BQ_LOCATION"
          value = var.bq_location
        }
        env {
          name  = "DBT_PROD_DATASET"
          value = var.prod_dataset_prefix
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }
      }
    }
  }

  # La imagen la maneja el pipeline de despliegue, no Terraform
  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [google_project_service.apis]
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  location = google_cloud_run_v2_job.dbt.location
  name     = google_cloud_run_v2_job.dbt.name
  role     = "roles/run.invoker"
  member   = google_service_account.scheduler.member
}

resource "google_cloud_run_v2_job_iam_member" "deployer_developer" {
  location = google_cloud_run_v2_job.dbt.location
  name     = google_cloud_run_v2_job.dbt.name
  role     = "roles/run.developer"
  member   = google_service_account.deployer.member
}

# ---------------------------------------------------------- Cloud Scheduler

resource "google_cloud_scheduler_job" "dbt_daily" {
  name             = "${var.job_name}-daily"
  region           = var.region
  schedule         = var.schedule
  time_zone        = "America/Bogota"
  attempt_deadline = "320s"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.dbt.name}:run"

    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler_invoker]
}

# ----------------------------------- GitHub → GCP sin llaves (Workload Identity)

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-dbt"
  display_name              = "GitHub dbt"

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub Actions"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Solo tu repo puede pedir credenciales
  attribute_condition = "assertion.repository == \"${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "deployer_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}
