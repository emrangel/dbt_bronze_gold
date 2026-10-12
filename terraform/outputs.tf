# Copia estos valores en GitHub → Settings → Secrets and variables → Actions → Variables
output "github_variables" {
  description = "Variables de GitHub Actions que usan ci.yml y deploy.yml."
  value = {
    GCP_PROJECT    = var.project_id
    GCP_REGION     = var.region
    BQ_LOCATION    = var.bq_location
    WIF_PROVIDER   = google_iam_workload_identity_pool_provider.github.name
    DEPLOYER_SA    = google_service_account.deployer.email
    AR_REPO        = google_artifact_registry_repository.dbt.repository_id
    JOB_NAME       = google_cloud_run_v2_job.dbt.name
    DBT_CI_DATASET = var.ci_dataset_prefix
  }
}
