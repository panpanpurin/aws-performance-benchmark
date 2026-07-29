# AniLove

RESTful API for anime and user watchlists (MyAnimeList style).

**One codebase** for **EC2**, **ECS**, and **AWS Lambda**: same business logic, dual entrypoints, dual Docker images.

**Workload profile:** I/O and database bound API (not a heavy compute loop). See [docs/WORKLOADS.md](../../docs/WORKLOADS.md).

## Features

- CRUD for Anime
- User registration and authentication (JWT)
- Personal anime watchlist (status + score 0 to 10)
- Password hashing with bcrypt
- PostgreSQL + Sequelize ORM
- Prometheus metrics at `/metrics` (including Lambda cold start)

## Tech stack

- Node.js 22, Express 5
- PostgreSQL, Sequelize
- JWT, bcrypt
- prom-client
- `@vendia/serverless-express` (Lambda only at runtime)

## Project layout

```text
apps/anilove/
├── src/                 # shared application code
│   ├── app.js
│   ├── metrics.js
│   ├── controllers/
│   ├── models/
│   └── ...
├── server.js            # EC2 / ECS entrypoint
├── index.js             # Lambda handler
├── Dockerfile           # EC2 / ECS image
└── Dockerfile.lambda    # Lambda container image
```

| Related | Link |
|---------|------|
| Benchmarks | [benchmarks/suites/anilove](../../benchmarks/suites/anilove) |
| Deploy | [docs/DEPLOY.md](../../docs/DEPLOY.md) |
| Infrastructure | [docs/INFRASTRUCTURE.md](../../docs/INFRASTRUCTURE.md) |
| Terraform | [terraform/](../../terraform/) |

## Environment variables

| Variable | Description |
|----------|-------------|
| `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_HOST`, `DB_PORT` | PostgreSQL / RDS |
| `DB_SSL` | TLS to DB (**default on**). Set `false` only for local Docker Postgres |
| `DB_SSL_REJECT_UNAUTHORIZED` | `true` to verify RDS CA; default `false` |
| `DB_SCHEMA` | Schema on shared DB: `ec2` / `ecs` / `lambda` / `public` |
| `JWT_SECRET` | JWT signing secret |
| `PORT` | HTTP port (default `3000`, EC2/ECS) |
| `SERVICE_NAME` | Prometheus label (optional) |
| `NODE_ENV` | e.g. `production` |

### Shared RDS

Use **one** RDS instance for all three platforms. Isolate data with schemas:

| Environment | `DB_SCHEMA` | Tables live in |
|-------------|-------------|----------------|
| EC2 | `ec2` | `ec2."Animes"`, … |
| ECS | `ecs` | `ecs."Animes"`, … |
| Lambda | `lambda` | `lambda."Animes"`, … |

TLS stays enabled (`DB_SSL=true` or omit). See `.env.example`.

## Local (EC2/ECS style)

```bash
npm install
npm run dev
# or
NODE_ENV=production PORT=3000 npm start
```

| URL | Purpose |
|-----|---------|
| http://localhost:3000/ | App |
| http://localhost:3000/health | Health |
| http://localhost:3000/metrics | Prometheus |

## Docker: EC2 / ECS

```bash
# from repo root
docker build -t anilove:ec2-ecs -f apps/anilove/Dockerfile apps/anilove
docker run -d -p 3000:3000 --env-file apps/anilove/.env anilove:ec2-ecs
```

Deploy the same image to ECS tasks or an EC2 host.

## Docker: AWS Lambda

```bash
docker build -t anilove:lambda -f apps/anilove/Dockerfile.lambda apps/anilove
# Push to ECR; handler: index.handler
```

Lambda detects `AWS_LAMBDA_FUNCTION_NAME` / `LAMBDA_TASK_ROOT` and records cold start metrics.

## API surface

| Method | Path | Notes |
|--------|------|--------|
| `GET` | `/`, `/health` | Health |
| `POST` | `/users`, `/users/login` | Auth |
| `GET` / `PUT` / `DELETE` | `/users/:id` | User (JWT on write) |
| CRUD | `/animes` | Anime |
| CRUD | `/users/:id/list` | Watchlist (JWT) |
| `GET` | `/metrics` | Prometheus |

## Metrics (cross platform)

| Metric | Notes |
|--------|--------|
| `app_total_execution_time_seconds` | Full `/animes` request |
| `app_internal_processing_time_seconds` | Total minus DB time |
| `app_cpu_usage_percent` / `app_ram_usage_mb` | Process gauges |
| `app_cold_start_duration_seconds` | Lambda only |
