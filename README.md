# dbt bronze → gold (BigQuery + dbt Core + Cloud Run + Terraform)

Proyecto mínimo con datos de Meta Ads de ejemplo que cubre el ciclo completo:
transformar con dbt, probar en cada PR, desplegar al hacer merge y ejecutar todos los días.

```
seeds/bronze_meta_ads.csv                   BRONZE  todo string, duplicados, nulls
        │ ref()
models/silver/stg_meta_ads.sql              SILVER  tipado, normalizado, deduplicado (view)
        │ ref()
models/gold/fct_campaign_performance.sql    GOLD    KPIs por campaña: CTR, CPC, CPM (table)
```

## Cómo se conecta todo

```
 PR abierto ──► GitHub Actions (ci.yml) ──► dbt build --target ci   ──► mkt_dbt_ci_*
                                       └──► terraform validate

 merge a main ─► GitHub Actions (deploy.yml) ─► docker build ─► Artifact Registry
 (o botón)                                   └► gcloud run jobs update

 6:00 a.m. ───► Cloud Scheduler ──► Cloud Run Job (dbt build --target prod) ──► mkt_dbt_*
```

GitHub se autentica en GCP con Workload Identity Federation, así que no hay llaves JSON en ningún lado.

| Target | Datasets | Quién lo usa |
|---|---|---|
| `dev` | `dbt_emra_bronze/_silver/_gold` | Tú, en tu máquina |
| `ci` | `mkt_dbt_ci_*` | Cada PR |
| `prod` | `mkt_dbt_*` | El job diario |

---

## 1. Desarrollo local

Las dependencias se manejan con [uv](https://docs.astral.sh/uv/): `pyproject.toml` declara
qué se necesita y `uv.lock` fija las versiones exactas que usan tu máquina, CI y Cloud Run.

```bash
uv sync                                # crea .venv con Python 3.12 y dbt
gcloud auth application-default login

export DBT_PROFILES_DIR=profiles       # PowerShell: $env:DBT_PROFILES_DIR="profiles"
export GCP_PROJECT=<tu-proyecto>       # PowerShell: $env:GCP_PROJECT="<tu-proyecto>"
uv run dbt debug
uv run dbt deps
uv run dbt build                       # seed + run + test, en orden
uv run dbt docs generate && uv run dbt docs serve   # linaje y documentación
```

Para actualizar dbt: cambia la versión en `pyproject.toml`, corre `uv lock` y haz commit de `uv.lock`.

Detrás de un proxy corporativo con su propio certificado, define `UV_SYSTEM_CERTS=1`.

Prueba romper algo: agrega al CSV una fila con país `VE` y corre `dbt build`.
El test `accepted_values` falla y gold no se reconstruye.

## 2. Infraestructura con Terraform (una sola vez)

Requisitos: Terraform 1.6 o superior, y permisos en el proyecto para crear service accounts,
pools de Workload Identity, Cloud Run, Scheduler, Artifact Registry y datasets.

### Preparación (una sola vez, con gcloud)

Terraform no puede crear estas dos cosas porque las necesita para arrancar:

```bash
# API que Terraform usa para dar permisos a nivel de proyecto
gcloud services enable cloudresourcemanager.googleapis.com --project <proyecto>

# Bucket donde Terraform guarda su state, con versionado por si se daña
gcloud storage buckets create gs://<proyecto>-tfstate --project <proyecto> --location=US --uniform-bucket-level-access
gcloud storage buckets update gs://<proyecto>-tfstate --versioning
```

### Crear la infraestructura

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edita project_id y github_repo
terraform init -backend-config="bucket=<proyecto>-tfstate"
terraform plan -out=tfplan                     # revisa: debe decir "0 to destroy"
terraform apply tfplan                         # aplica exactamente lo revisado
terraform output github_variables
```

Si `apply` falla a mitad de camino (por ejemplo, por un error de red o porque una API
recién activada aún no responde), vuelve a correr `terraform plan -out=tfplan` y
`terraform apply tfplan`: solo crea lo que faltó.

`.terraform.lock.hcl` fija la versión del proveedor de Google; súbelo a git junto con los `.tf`.

Terraform crea:
- Seis datasets: los de prod (`mkt_dbt_*`) y los de CI (`mkt_dbt_ci_*`).
- Tres service accounts con permisos mínimos: `dbt-runner`, `dbt-scheduler` y `dbt-deployer`.
- Artifact Registry, que conserva las últimas 10 imágenes.
- El Cloud Run Job y su Cloud Scheduler.
- El pool de Workload Identity, restringido a tu repo.

Como el proyecto es compartido, todos los permisos son aditivos (`*_iam_member`).
Terraform no toca los permisos de otros equipos ni apaga APIs al hacer `destroy`.

## 3. Conectar GitHub

1. Sube el proyecto a tu repo.
2. En Settings → Secrets and variables → Actions → **Variables**, crea cada valor que muestra `terraform output github_variables`.
3. Opcional: en Settings → Environments, crea `production` y agrega "Required reviewers". Así cada despliegue espera tu aprobación.

## 4. Primer despliegue

Hasta que corre el primer despliegue, el job usa una imagen de prueba de Google. Para desplegar:
Actions → **deploy** → Run workflow → marca `run_now`.

De ahí en adelante:
- **Cambias SQL** → abres PR → `ci` corre dbt contra `mkt_dbt_ci_*`.
- **Merge a main** → `deploy` construye la imagen y actualiza el job.
- **Todos los días a las 6:00** → Scheduler ejecuta el job.
- **Cambias infraestructura** → editas `terraform/` y corres `terraform apply` desde tu máquina.

Para ver los logs: Cloud Run → Jobs → `dbt-bronze-gold` → Executions.

## 5. Pasarlo a tu bronze real

1. Descomenta el bloque `sources:` en `models/silver/_silver.yml` y apúntalo a tu tabla de Adverity.
2. En `stg_meta_ads.sql`, cambia `{{ ref('bronze_meta_ads') }}` por `{{ source('adverity', 'meta_ads_raw') }}`.
3. En `terraform.tfvars`, agrega ese dataset a `source_datasets` para que las service accounts puedan leerlo, y corre `terraform apply`.
4. Borra el seed y, si la tabla es grande, convierte silver en `incremental`.
