variable "project_id" {
  description = "Proyecto GCP donde vive todo."
  type        = string
}

variable "region" {
  description = "Región de Cloud Run, Scheduler y Artifact Registry."
  type        = string
  default     = "us-central1"
}

variable "bq_location" {
  description = "Ubicación de los datasets de BigQuery (debe coincidir con tu bronze)."
  type        = string
  default     = "US"
}

variable "github_repo" {
  description = "Repo que puede desplegar, formato owner/repo."
  type        = string
}

variable "job_name" {
  description = "Nombre del Cloud Run Job."
  type        = string
  default     = "dbt-bronze-gold"
}

variable "schedule" {
  description = "Cron de la ejecución diaria (hora America/Bogota)."
  type        = string
  default     = "0 6 * * *"
}

variable "prod_dataset_prefix" {
  description = "Prefijo de los datasets de prod: <prefijo>_bronze, _silver, _gold."
  type        = string
  default     = "mkt_dbt"
}

variable "ci_dataset_prefix" {
  description = "Prefijo de los datasets que usan los PR."
  type        = string
  default     = "mkt_dbt_ci"
}

variable "source_datasets" {
  description = "Datasets existentes que dbt solo necesita leer (por ejemplo tu bronze de Adverity)."
  type        = list(string)
  default     = []
}
