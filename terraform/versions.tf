terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }

  # El bucket se pasa al hacer init:
  #   terraform init -backend-config="bucket=<tu-bucket-de-state>"
  backend "gcs" {
    prefix = "dbt-bronze-gold"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
