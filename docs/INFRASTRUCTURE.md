# Target AWS infrastructure

Region: **ap-northeast-1** (Tokyo). Same VPC for all experiment components so differences are attributable to the compute model (EC2, ECS on EC2, Lambda), not to network or edge layout.

This document is the reference for Terraform. Application packaging and env vars: [DEPLOY.md](./DEPLOY.md). Workload bounds: [WORKLOADS.md](./WORKLOADS.md).

---

## Design goals

1. Equivalent, controlled conditions for the three apps on three compute models.
2. External access is **HTTPS managed by AWS** on all three platforms (ALB+ACM for EC2/ECS; Function URL TLS for Lambda).
3. Isolation between **apps** (separate EC2 instances, separate ECS services, separate Lambda functions).
4. **One Application Load Balancer** for all EC2 and ECS backends.
5. **One ECS cluster** hosting all three app services (scale idle services to 0 during focused runs).
6. **One shared RDS** for AniLove across EC2, ECS, and Lambda (see [Database](#database-rds--anilove-only)).
7. CSV and Thumbnail remain **stateless** (no RDS).

---

## Network and edge

| Component | Configuration |
|-----------|----------------|
| VPC | Single VPC for EC2, ECS, Lambda (when VPC-attached), RDS |
| Availability | Three AZs for ALB and ECS capacity |
| ALB | **One** internet-facing ALB, IPv4, HTTPS:443 (e.g. `apps-alb`) |
| TLS on ALB | **One** ACM certificate (DNS validation in Terraform), same TLS security policy on the HTTPS listener |
| HTTP | Optional listener :80 redirect to HTTPS |
| Lambda edge | **Function URL only** - AWS-managed HTTPS (not behind the ALB) |
| DNS | Route 53 hosted zone; alias records for EC2/ECS hostnames to the **single ALB**; Lambda custom domains optional (default is Function URL hostname) |

### HTTPS on all three platforms

| Platform | How HTTPS is provided |
|----------|------------------------|
| EC2 | Client -> ALB (ACM terminates TLS) -> HTTP to instance |
| ECS on EC2 | Client -> **same ALB** (same ACM cert + TLS policy) -> HTTP to task |
| Lambda | Client -> **Function URL** (AWS-managed TLS) -> Lambda invoke |

EC2 and ECS share the ALB edge path. Lambda does **not** use the ALB; Function URL HTTPS is the serverless equivalent for external access.

### TLS / ACM (Terraform)

| Item | Choice |
|------|--------|
| Certificate | Single ACM cert (wildcard `*.example.com` and/or SANs for each hostname) |
| Validation | **DNS validation** via Route 53 (automated in Terraform) |
| Attachment | Same cert ARN on the **one** ALB HTTPS listener |
| SSL policy | One policy for that listener (e.g. `ELBSecurityPolicy-TLS13-1-2-2021-06` or current AWS recommended) |
| Lambda | No ALB cert; Function URL provides HTTPS |

### Layer-7 routing (EC2 + ECS on one ALB)

Clients use HTTPS only. Route 53 resolves each EC2/ECS subdomain to the **same ALB**. The ALB:

1. Terminates TLS with the shared ACM certificate.
2. Routes by **Host** header to a target group (EC2 instance or ECS service).
3. Forwards **HTTP** internally to backends on app ports.

```text
Clients (HTTPS)
       |
   Route 53
       |
       v
  Single ALB  (HTTPS:443, one ACM cert, one TLS policy)
       |
 Host-based rules (L7)
       |
  +----+----+----+----+----+----
  |    |    |    |    |    |
  v    v    v    v    v    v
 TG   TG   TG   TG   TG   TG
 EC2  EC2  EC2  ECS  ECS  ECS
 (per app)      (per app)
  :3000/:3001/:8000

Lambda (separate path):
Clients (HTTPS) --> Function URL (AWS TLS) --> Lambda function
```

### Suggested hostnames (examples)

Replace with the real domain in Terraform/Route 53. Repo Artillery/Prometheus targets stay placeholders until apply.

| App | EC2 (ALB Host) | ECS (ALB Host) | Lambda |
|-----|----------------|----------------|--------|
| AniLove | `anilove-ec2.<domain>` | `anilove-ecs.<domain>` | Function URL (AWS HTTPS) |
| CSV | `csv-processor-ec2.<domain>` | `csv-processor-ecs.<domain>` | Function URL |
| Thumbnail | `thumbnail-generator-ec2.<domain>` | `thumbnail-ecs.<domain>` | Function URL |

App listen ports (all platforms):

| App | Port |
|-----|------|
| AniLove | 3000 |
| Thumbnail | 3001 |
| CSV | 8000 |

Health checks: `GET /health` on each target group (EC2 and ECS).

Example ALB Host rules (same listener):

| Host header | Target group | Backend port |
|-------------|--------------|--------------|
| `anilove-ec2.<domain>` | EC2 AniLove TG | 3000 |
| `csv-processor-ec2.<domain>` | EC2 CSV TG | 8000 |
| `thumbnail-generator-ec2.<domain>` | EC2 Thumbnail TG | 3001 |
| `anilove-ecs.<domain>` | ECS AniLove TG | 3000 |
| `csv-processor-ecs.<domain>` | ECS CSV TG | 8000 |
| `thumbnail-ecs.<domain>` | ECS Thumbnail TG | 3001 |
| (default) | default TG or fixed 404 | - |

---

## Database (RDS) - AniLove only

**One RDS instance** for AniLove on EC2, ECS, and Lambda (not one DB per platform).

| Aspect | Value |
|--------|--------|
| Count | **1** PostgreSQL instance |
| Class | `db.t4g.micro` (example) |
| Engine | PostgreSQL (e.g. 17.x) |
| Storage | e.g. 20 GiB gp2/gp3 |
| Placement | Same VPC, private subnets |
| Multi-AZ | Off unless required |
| Access | Port **5432** only from AniLove security groups (EC2, ECS tasks, Lambda) |

### Schema isolation

| Platform | `DB_SCHEMA` |
|----------|-------------|
| EC2 | `ec2` |
| ECS | `ecs` |
| Lambda | `lambda` |

The app creates the schema on startup. See [DEPLOY.md](./DEPLOY.md).

Concurrent platform load tests share RDS CPU/IOPS; schemas isolate data only.

CSV and Thumbnail: **no RDS**.

---

## EC2 (VM)

| Item | Configuration |
|------|----------------|
| Region | ap-northeast-1 |
| Instance type | `t2.micro` (1 vCPU, 1 GiB) |
| Count | One dedicated instance **per app** (three instances) |
| AMI | Amazon Linux 2023 x86_64 (pin AMI id in Terraform variables) |
| Root volume | EBS for OS + runtime |
| Public app access | **Only via the shared ALB** |
| Security group | Ingress from **ALB SG** only on 3000 / 3001 / 8000 |
| Experiment practice | Keep **one app instance running at a time** when measuring a single app, if desired |

Images: `apps/*/Dockerfile`. Prefer Docker for parity with ECS/Lambda artifacts.

---

## ECS on EC2 (containers)

| Item | Configuration |
|------|----------------|
| Layout | **One ECS cluster** for all three apps |
| Capacity | One Auto Scaling Group (or capacity provider) for the cluster |
| Instance type | `t3.small` (physical capacity); fairness via **task** limits |
| AMI | ECS-optimized AMI (pin in variables) |
| AZs | Three AZs |
| Services | Three services (AniLove, CSV, Thumbnail) on the **same cluster** |
| Task resources | `cpu = 1024`, `memory = 1024`, `memoryReservation = 512` (~1 vCPU, ~1 GiB logical) |
| Network mode | `awsvpc`; ports 3000 / 3001 / 8000 |
| Images | ECR (same long-running Dockerfiles as EC2) |
| Logs | CloudWatch `awslogs` |
| ALB | Same shared ALB; Host rules to ECS target groups; health on `/health` |
| AniLove RDS | Task SG may reach the shared RDS SG |
| Experiment practice | Scale other services to **desired count 0** so capacity is dedicated to the app under test |

---

## Lambda (serverless)

| Item | Configuration |
|------|----------------|
| Packaging | Container images from ECR (`Dockerfile.lambda`) |
| Memory | 1024 MB |
| Ephemeral storage | 1024 MB |
| Timeout | 30 s |
| Architecture | x86_64 |
| Public HTTPS | **Function URL only** (AWS-managed TLS; **not** the ALB) |
| AniLove | VPC if RDS is private; secrets from Secrets Manager / SSM |
| CSV | Python 3.12 Lambda base + Mangum |
| Thumbnail / AniLove | Node.js 22 Lambda base + serverless-express |
| Logs | CloudWatch |

Build parity: same app source as EC2/ECS; only image base and handler differ.

---

## Parameter summary (compute equivalence)

| Component | Main parameters |
|-----------|-----------------|
| **EC2** | `t2.micro`; 1 vCPU / 1 GiB; via **shared ALB** HTTPS |
| **ECS on EC2** | **One cluster**; task `cpu=1024`, `memory=1024`; via **same ALB** HTTPS |
| **Lambda** | 1024 MB memory; Function URL HTTPS (AWS-managed); ECR images |
| **Edge TLS** | One ACM cert (DNS-validated); one TLS policy on the ALB listener |
| **RDS** | **One** `db.t4g.micro` for AniLove; schemas `ec2` / `ecs` / `lambda` |

---

## Security groups (minimal rules)

| Source | Destination | Port | Purpose |
|--------|-------------|------|---------|
| Internet | ALB SG | 443 (80 optional redirect) | Public HTTPS |
| Internet | Lambda Function URL | 443 | AWS-managed HTTPS |
| ALB SG | EC2 app SGs | 3000 / 3001 / 8000 | Backend HTTP |
| ALB SG | ECS task SGs | 3000 / 3001 / 8000 | Backend HTTP |
| AniLove app SGs (EC2, ECS, Lambda) | RDS SG | 5432 | Postgres |

No public 5432. No public direct access to EC2/ECS app ports.

---

## Secrets and configuration

| Secret / config | Consumers |
|-----------------|-----------|
| RDS password | AniLove on EC2, ECS, Lambda |
| `JWT_SECRET` | AniLove on all three |
| DB host/name/user/port | AniLove |
| `DB_SCHEMA` | Per platform: `ec2` / `ecs` / `lambda` |

Prefer Secrets Manager or SSM in Terraform; inject via instance role / task role / Lambda env.

---

## Observability (outside or beside Terraform)

App metrics: `GET /metrics`.  
Tooling: [`benchmarks/`](../benchmarks/), [`local/`](../local/).

After Terraform apply, fill:

- `benchmarks/suites/*/prometheus.yml` app targets  
- `benchmarks/suites/*/artillery/test-*.yml` `target` URLs  

See [PROMETHEUS-TARGETS.md](../benchmarks/docs/PROMETHEUS-TARGETS.md) and [ARTILLERY-TARGETS.md](../benchmarks/docs/ARTILLERY-TARGETS.md).

---

## Terraform

Stack: [`terraform/`](../terraform/). Apply guide: [terraform/README.md](../terraform/README.md).

| Area | Location |
|------|----------|
| IAM | [IAM.md](./IAM.md), `modules/iam` |
| Remote state | `bootstrap/`, `versions.tf` backend |
| AMI / digests / TLS / sizes | `variables.tf`, `terraform.tfvars.example` |
| Tags | `locals.tf`, `providers.tf` |
| Secrets | `modules/secrets` |
| Security groups | `modules/security_groups` |
| Log retention | `modules/observability` |
| Network, ALB, ACM, ECR, RDS | matching modules |
| EC2 / ECS / Lambda | `enable_ec2`, `enable_ecs`, `enable_lambda` (default off until images exist) |
| Targets for benchmarks | `generated/benchmark-targets.json` after apply |

Terraform does not build images or run Artillery. Push images to ECR, then enable compute flags.

---

## Alignment with this repository

| Infra concern | Repo support |
|---------------|--------------|
| Dual Docker images | `apps/*/Dockerfile`, `Dockerfile.lambda` |
| Shared AniLove DB + schemas | `DB_SCHEMA`, TLS defaults in app |
| Stateless CSV / Thumbnail | No DB env required |
| HTTPS on all three | ALB+ACM (EC2/ECS); Function URL (Lambda) |
| Fair 1 vCPU profile | Task/Lambda/EC2 sizing; app thread pins for CSV/thumbnail |

---

## Explicit non-goals

- Multi-AZ RDS (optional later)
- Separate ALB per compute model (superseded by **one ALB**)
- Separate ECS cluster per app (superseded by **one cluster**, three services)
- Three RDS instances (superseded by **one RDS** + schemas)
- Putting Lambda behind the ALB (Function URL is the HTTPS entry for Lambda)
