# Pokémon CSV Processor API

Python FastAPI service to upload, filter, group, and transform CSV files.

**One codebase** for **EC2**, **ECS**, and **AWS Lambda**.

**Workload profile:** CPU and memory bound data processing (pandas). See [docs/WORKLOADS.md](../../docs/WORKLOADS.md).

## Features

- Upload `.csv` via `POST /process`
- Filter rows (JSON operators: `$gt`, `$lt`, `$eq`, …)
- Select columns
- Group + aggregate: `sum`, `mean`, `count`, `max`, `min`
- Prometheus metrics at `/metrics` (cold start on Lambda)

## Project layout

```text
apps/csv-processor/
├── app/
│   ├── main.py          # FastAPI app + Mangum handler
│   ├── metrics.py
│   ├── api/routes.py
│   ├── services/
│   └── utils/
├── Dockerfile           # EC2 / ECS
├── Dockerfile.lambda    # Lambda
└── requirements.txt
```

| Related | Link |
|---------|------|
| Benchmarks | [benchmarks/suites/csv-processor](../../benchmarks/suites/csv-processor) |
| Deploy | [docs/DEPLOY.md](../../docs/DEPLOY.md) |
| Infrastructure | [docs/INFRASTRUCTURE.md](../../docs/INFRASTRUCTURE.md) |
| Terraform | [terraform/](../../terraform/) |

## Local

```bash
python -m venv venv
# Windows: venv\Scripts\activate
source venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

## Docker: EC2 / ECS

```bash
# from repo root
docker build -t csv-processor:ec2-ecs -f apps/csv-processor/Dockerfile apps/csv-processor
docker run -d -p 8000:8000 csv-processor:ec2-ecs
```

## Docker: Lambda

```bash
docker build -t csv-processor:lambda -f apps/csv-processor/Dockerfile.lambda apps/csv-processor
# Push to ECR; handler: app.main.handler
```

## API

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/process` | Multipart: `file` + optional form JSON fields |
| `GET` | `/health` | Health |
| `GET` | `/metrics` | Prometheus |

Form fields (optional JSON strings): `filters`, `columns`, `grouping`, `operations`.

BLAS threads are pinned to 1 (`OMP_NUM_THREADS` / `OPENBLAS_NUM_THREADS`) for fair 1 vCPU comparison.
