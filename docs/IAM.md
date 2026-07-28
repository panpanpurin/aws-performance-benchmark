# IAM: deploy path and runtime roles

Roles for Terraform applies and for apps at runtime.
Architecture: [INFRASTRUCTURE.md](./INFRASTRUCTURE.md).
Code: `terraform/modules/iam`.

---

## Deploy path

Who runs `terraform plan/apply` and pushes images to ECR.

| Principal | Purpose |
|-----------|---------|
| Deploy policy (SSO or CI) | Attach `iam_deploy_policy_arn` from Terraform outputs |
| Deploy role (optional) | `create_deploy_role = true` + trusted principal ARNs |

Capabilities: VPC, ALB, EC2, ECS, Lambda, ECR, RDS, Secrets Manager, ACM, Route 53 (project zone), CloudWatch Logs, state S3/DynamoDB, `iam:PassRole` only for project roles (`<project>-*`).

Do not use long-lived admin access keys in the repo or images.

---

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

ECS agent: ECR pull, log streams, secret injection from the task definition.

### ECS task (`ecs-task`)

App process. AniLove may read secrets if not only injected at start. CSV/Thumbnail do not need a task role for secrets when injection is used.

### Lambda (`lambda-<app>`)

| App | Permissions |
|-----|-------------|
| All | CloudWatch Logs |
| AniLove | Secrets + VPC ENI (private RDS) |
| CSV / Thumbnail | Logs only |

---

## Secrets

| Secret path | Contents | Used by |
|-------------|----------|---------|
| `<project>/anilove/db` | username, password, host, port, dbname | AniLove on all platforms |
| `<project>/anilove/jwt` | JWT_SECRET | AniLove on all platforms |

`DB_SCHEMA` is set per platform in Terraform/env (`ec2` / `ecs` / `lambda`), not in the shared secret.

---

## PassRole

Deploy may pass only:

- EC2 instance role  
- ECS execution and task roles  
- Lambda execution roles  

ARNs match roles created by this stack.

---

## Tags

Same defaults as other resources: `Project`, `ManagedBy=terraform`, `Component=iam`.

---

## Checklist

1. No access keys in git or images.  
2. Deploy via SSO, role assumption, or CI OIDC.  
3. Runtime roles exist for EC2, ECS, Lambda.  
4. Secrets limited by ARN.  
5. PassRole limited to project roles.  
