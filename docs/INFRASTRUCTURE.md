# Target AWS infrastructure

**Region:** ap-northeast-1 (Tokyo).

Same VPC for all components so differences come from the compute model (EC2, ECS on EC2, Lambda), not from network or edge layout.

| Related | Link |
|---------|------|
| Packaging and env | [DEPLOY.md](./DEPLOY.md) |
| Workloads | [WORKLOADS.md](./WORKLOADS.md) |
| Terraform apply | [terraform/README.md](../terraform/README.md) |
| IAM | [IAM.md](./IAM.md) |

## Design goals

1. Equivalent conditions for three apps on three compute models
2. External access uses HTTPS managed by AWS when DNS and ACM are configured (ALB + ACM for EC2/ECS; Function URL for Lambda)
3. Isolation between apps (separate EC2 instances, ECS services, Lambda functions)
4. **One** Application Load Balancer for all EC2 and ECS backends
5. **One** ECS cluster with three services (scale idle services to 0 during focused runs)
6. **One** shared RDS for AniLove across EC2, ECS, and Lambda
7. CSV and Thumbnail stay **stateless** (no RDS)

## Network and edge

| Component | Configuration |
|-----------|----------------|
| VPC | Single VPC for EC2, ECS, Lambda (when VPC attached), RDS |
| Availability | Three AZs for ALB and ECS capacity |
| ALB | One internet facing ALB, IPv4 |
| TLS on ALB | One ACM certificate (DNS validation), one TLS policy on HTTPS 443 |
| HTTP | Listener on 80; redirects to HTTPS when a certificate is set |
| Without domain | ALB can run HTTP only until `domain_name` and `route53_zone_id` are set |
| Lambda edge | Function URL only (AWS managed HTTPS; not behind the ALB) |
| DNS | Route 53 aliases for EC2/ECS hostnames to the single ALB |

### HTTPS by platform

| Platform | Path |
|----------|------|
| EC2 | Client to ALB (ACM) to HTTP on the instance |
| ECS on EC2 | Client to the **same** ALB to HTTP on the task |
| Lambda | Client to Function URL (AWS TLS) to the function |

### Layer 7 routing (EC2 and ECS)

```text
Clients (HTTPS)
       |
   Route 53
       |
       v
  Single ALB  (HTTPS 443, one ACM cert, one TLS policy)
       |
 Host based rules
       |
  EC2 TGs (per app)     ECS TGs (per app)
  :3000 / :3001 / :8000

Lambda:
Clients (HTTPS) --> Function URL --> Lambda
```

### Hostnames (examples)

Set `domain_name` in Terraform. Artillery and Prometheus targets stay placeholders until apply.

| App | EC2 | ECS | Lambda |
|-----|-----|-----|--------|
| AniLove | `anilove-ec2.<domain>` | `anilove-ecs.<domain>` | Function URL |
| CSV | `csv-processor-ec2.<domain>` | `csv-processor-ecs.<domain>` | Function URL |
| Thumbnail | `thumbnail-generator-ec2.<domain>` | `thumbnail-ecs.<domain>` | Function URL |

| App | Port |
|-----|------|
| AniLove | 3000 |
| Thumbnail | 3001 |
| CSV | 8000 |

Health checks: `GET /health` on each EC2 and ECS target group.

## Database (RDS): AniLove only

**One** PostgreSQL instance for AniLove on all three platforms.

| Aspect | Value |
|--------|--------|
| Class | `db.t4g.micro` (default in Terraform) |
| Engine | PostgreSQL (version pin in variables) |
| Storage | 20 GiB gp3 (default) |
| Placement | Private subnets |
| Multi AZ | Off |
| Access | Port **5432** only from EC2, ECS, and Lambda security groups |

### Schema isolation

| Platform | `DB_SCHEMA` |
|----------|-------------|
| EC2 | `ec2` |
| ECS | `ecs` |
| Lambda | `lambda` |

The app creates the schema on startup. Concurrent platform load shares RDS CPU and IOPS; schemas isolate data only.

CSV and Thumbnail: **no RDS**.

## EC2

| Item | Configuration |
|------|----------------|
| Region | ap-northeast-1 |
| Instance type | `t2.micro` |
| Count | One instance per app |
| AMI | Amazon Linux 2023 (pin in `tfvars`, or SSM latest) |
| Public access | Only via shared ALB |
| Security group | Ingress from ALB SG on app ports only |
| Images | `apps/*/Dockerfile` |
| Measurement | Prefer one app under load at a time when comparing a single workload |

## ECS on EC2

| Item | Configuration |
|------|----------------|
| Layout | One cluster, three services |
| Capacity | ASG + capacity provider |
| Instance type | `t3.small` host; fairness via **task** limits |
| Task | `cpu=1024`, `memory=1024` |
| Network | `awsvpc` |
| Images | Same long running Dockerfiles as EC2 (ECR) |
| ALB | Same shared ALB |
| Measurement | Scale other services to desired count **0** when focusing one app |

## Lambda

| Item | Configuration |
|------|----------------|
| Packaging | ECR container images (`Dockerfile.lambda`) |
| Memory / ephemeral | 1024 MB each |
| Timeout | 30 s |
| Architecture | x86_64 |
| HTTPS | Function URL only |
| AniLove | VPC attached for private RDS; secrets injected |
| CSV | Python 3.12 + Mangum |
| Thumbnail / AniLove | Node.js 22 + serverless express |

## Parameter summary

| Component | Main parameters |
|-----------|-----------------|
| EC2 | `t2.micro`; shared ALB |
| ECS | One cluster; task 1024 CPU / 1024 MiB; same ALB |
| Lambda | 1024 MB; Function URL |
| TLS | One ACM cert + TLS policy on ALB (when domain set) |
| RDS | One `db.t4g.micro`; schemas `ec2` / `ecs` / `lambda` |

## Security groups

| Source | Destination | Port |
|--------|-------------|------|
| Internet | ALB | 443, 80 |
| Internet | Lambda Function URL | 443 (AWS managed) |
| ALB | EC2 / ECS tasks | 3000, 3001, 8000 |
| AniLove compute (EC2, ECS, Lambda) | RDS | 5432 |

No public 5432. No direct public access to app ports on EC2 or ECS.

## Secrets

| Secret | Contents | Consumers |
|--------|----------|-----------|
| `<project>/anilove/db` | username, password, host, port, dbname | AniLove all platforms |
| `<project>/anilove/jwt` | JWT_SECRET | AniLove all platforms |

`DB_SCHEMA` is set per platform in env or Terraform, not in the shared secret. See [IAM.md](./IAM.md).

## Observability

App metrics: `GET /metrics`.

Local and AWS tooling: [local/](../local/), [benchmarks/](../benchmarks/).

After apply, use Terraform outputs or `generated/benchmark-targets.json` to fill:

- `benchmarks/suites/*/prometheus.yml`
- `benchmarks/suites/*/artillery/test-*.yml`

See [PROMETHEUS-TARGETS.md](../benchmarks/docs/PROMETHEUS-TARGETS.md) and [ARTILLERY-TARGETS.md](../benchmarks/docs/ARTILLERY-TARGETS.md).

## Terraform

| Area | Location |
|------|----------|
| Stack | [terraform/](../terraform/) |
| IAM | [IAM.md](./IAM.md), `modules/iam` |
| Remote state | `bootstrap/`, backend in `backend.tf` (gitignored) |
| Pins | AMI, digests, TLS policy, sizes in `variables.tf` |
| Compute flags | `enable_ec2` / `enable_ecs` / `enable_lambda` (default off until images exist) |

Terraform does not build images or run Artillery.

## Repo alignment

| Concern | Support |
|---------|---------|
| Dual images | `apps/*/Dockerfile`, `Dockerfile.lambda` |
| Shared DB + schemas | `DB_SCHEMA`, TLS defaults |
| Stateless CSV / Thumbnail | No DB env |
| HTTPS | ALB + ACM (EC2/ECS); Function URL (Lambda) |
| About 1 vCPU profile | EC2 / task / Lambda sizing; thread pins on CSV and thumbnail |

## Non goals

- Multi AZ RDS
- Separate ALB or ECS cluster per app
- Three RDS instances
- Lambda behind the ALB
