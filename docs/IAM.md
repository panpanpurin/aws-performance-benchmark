# IAM: deploy path and runtime roles

Roles for Terraform applies and for apps at runtime.

| Related | Link |
|---------|------|
| Architecture | [INFRASTRUCTURE.md](./INFRASTRUCTURE.md) |
| Code | `terraform/modules/iam` |
| ECS host role | also under `modules/ecs_cluster` |

## Deploy path

Who runs `terraform plan/apply` and pushes images to ECR.

| Principal | Purpose |
|-----------|---------|
| Deploy policy | Attach output `iam_deploy_policy_arn` to SSO or CI |
| Deploy role (optional) | `create_deploy_role = true` + `deploy_role_trusted_principals` |

Covers VPC, ALB, EC2, ECS, Lambda, ECR, RDS, Secrets Manager, ACM, Route 53 (project zone), CloudWatch Logs, state S3/DynamoDB, and `iam:PassRole` only for project roles (`<project>-*`).

Do not put long lived admin access keys in the repo or images.

## Runtime roles

### EC2 (`ec2-app` instance profile)

Shared by the three app instances.

| Permission | Scope |
|------------|--------|
| ECR pull | Project repositories |
| Secrets Manager Get | AniLove secrets |
| CloudWatch Logs | `/ec2/*` |
| SSM Session Manager | Managed policy (no open SSH) |

### ECS execution (`ecs-execution`)

Agent: ECR pull, log streams, secret injection from the task definition.

### ECS task (`ecs-task`)

App process. AniLove may read secrets if not only injected at start. CSV and Thumbnail usually need no task role secrets when injection is used.

### ECS container instance (`ecs-instance`)

Created with the ECS module: ECS agent and SSM on capacity hosts.

### Lambda (`lambda-<app>`)

| App | Permissions |
|-----|-------------|
| All | CloudWatch Logs |
| AniLove | Secrets + VPC ENI (private RDS) |
| CSV / Thumbnail | Logs only |

## Secrets

| Path | Contents | Used by |
|------|----------|---------|
| `<project>/anilove/db` | username, password, host, port, dbname | AniLove all platforms |
| `<project>/anilove/jwt` | JWT_SECRET | AniLove all platforms |

`DB_SCHEMA` is set per platform in env or Terraform, not in these secrets.

## PassRole

Deploy may pass only EC2 app role, ECS execution and task roles, and Lambda execution roles created by this stack.

## Tags

Defaults: `Project`, `ManagedBy=terraform`, `Component=iam` (plus stack tags).

## Checklist

1. No access keys in git or images.
2. Deploy via SSO, role assumption, or CI OIDC.
3. Runtime roles exist for EC2, ECS, and Lambda.
4. Secrets limited by ARN.
5. PassRole limited to project roles.
