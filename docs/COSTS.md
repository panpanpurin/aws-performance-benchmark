# Cost estimate

What this stack costs to run in **ap-northeast-1 (Tokyo)**, and which parts
dominate the bill.

Summary: a full benchmark sweep across all three suites consumes about **$0.39**
of Lambda compute, and one apply-measure-destroy session costs about **$8.87**.
Leaving the same stack running for a month would cost about **$734**, because
non-burstable instances bill by the hour whether or not a test is running. The
stack is designed to be applied, measured, and destroyed.

Most of that cost is the deliberate choice of non-burstable `c6i.large` over
the much cheaper `t2.micro` / `t3.small` used in earlier revisions: burstable
instances throttle once CPU credits are exhausted, and t2 and t3 default to
opposite credit modes. The reasoning, and how to switch back for cheap smoke
tests, is in
[INFRASTRUCTURE.md](./INFRASTRUCTURE.md#instance-type-choice-why-not-burstable).

## Price source

All unit prices below were read from the AWS Price List API on **2026-07-31**
for `Asia Pacific (Tokyo)`, on-demand, no reservations or savings plans.
Reproduce any of them with:

```bash
aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
  --filters "Type=TERM_MATCH,Field=instanceType,Value=c6i.large" \
            "Type=TERM_MATCH,Field=location,Value=Asia Pacific (Tokyo)" \
            "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
            "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
            "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
            "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
  --max-results 1
```

| Resource | Unit price (Tokyo) |
|----------|--------------------|
| EC2 `c6i.large` (non-burstable) | $0.1070 / hour |
| EC2 `t2.micro` / `t3.small` (burstable, no longer used) | $0.0152 / $0.0272 per hour |
| EBS `gp3` | $0.096 / GB-month |
| NAT gateway | $0.062 / hour + $0.062 / GB processed |
| ALB | $0.0243 / hour + $0.008 / LCU-hour |
| RDS `db.m6g.large` PostgreSQL, Single-AZ | $0.221 / hour |
| RDS `db.t4g.micro` (burstable, no longer used) | $0.025 / hour |
| RDS `gp3` storage | $0.138 / GB-month |
| Public IPv4 address, in use | $0.005 / hour |
| Lambda compute | $0.0000166667 / GB-second |
| Lambda requests | $0.20 / million |
| Secrets Manager | $0.40 / secret-month |
| ECR storage | $0.10 / GB-month |
| CloudWatch Logs ingestion | $0.76 / GB |

Prices change. Re-run the commands rather than trusting this table.

## What the stack contains

From `terraform/`, with the committed `terraform.tfvars`:

- 1 VPC across 3 AZs, 3 public and 3 private subnets, **1** NAT gateway
- 1 ALB, public, HTTPS on 443 with an ACM certificate (free) and 80 redirecting
  to it; HTTP-only if `domain_name` is left empty
- 1 Route 53 hosted zone, $0.50/month, billed whether or not the stack is up
  since `make destroy` does not touch the zone or the domain registration
- 3 EC2 app instances (`c6i.large`, one per app), private subnets, 20 GB gp3 each;
  each app container is capped at 1 vCPU / 1024 MB to match the ECS task
- 1 ECS cluster on an ASG of `c6i.large`, 30 GB gp3 each
- 1 RDS `db.m6g.large` (non-burstable), 20 GB gp3, Single-AZ, no backup
  retention, Performance Insights on the free 7-day tier
- 3 Lambda functions, 1769 MB (one full vCPU), container image, Function URLs
- 6 ECR images (3 apps x EC2/ECS + Lambda variants), 2 secrets, 9 log groups

Both EC2 apps and ECS container instances sit in **private** subnets, so all
their egress (ECR pulls, package downloads) passes through the NAT gateway.

## Scenario A: everything left running, 730 hours

The ECS ASG defaults to 1 instance; `make ecs-up` scales it to 3. This table
uses 3, the state an actual benchmark runs in.

| Line item | Calculation | $/month |
|-----------|-------------|---------|
| ECS instances, 3x `c6i.large` | 3 x 730 x $0.1070 | 234.33 |
| NAT gateway hours | 730 x $0.062 | 45.26 |
| EC2 apps, 3x `c6i.large` | 3 x 730 x $0.1070 | 234.33 |
| RDS instance | 730 x $0.025 | 18.25 |
| ALB hours | 730 x $0.0243 | 17.74 |
| Public IPv4, 3 ALB nodes + 1 NAT | 4 x 730 x $0.005 | 14.60 |
| ECS EBS, 3x 30 GB gp3 | 90 x $0.096 | 8.64 |
| ALB LCU (assume ~1 average) | 730 x $0.008 | 5.84 |
| EC2 EBS, 3x 20 GB gp3 | 60 x $0.096 | 5.76 |
| RDS storage | 20 x $0.138 | 2.76 |
| CloudWatch Logs (assume ~2 GB) | 2 x $0.76 | 1.52 |
| Secrets Manager, 2 secrets | 2 x $0.40 | 0.80 |
| NAT data processing (assume ~10 GB) | 10 x $0.062 | 0.62 |
| ECR storage (assume ~2.5 GB) | 2.5 x $0.10 | 0.25 |
| S3 + DynamoDB state backend | negligible | 0.10 |
| Lambda | idle, no invocations | 0.00 |
| **Total** | | **≈ 590.80** |

Compute alone (EC2 apps plus ECS instances) is 79% of the bill. Non-burstable
instances are what make an always-on stack expensive; see Scenario C.

Rows marked "assume" depend on how much you actually run; the rest are fixed
by the stack's shape.

## Scenario B: ECS scaled to zero between runs

`make ecs-down` sets the ASG to 0, terminating the instances and their volumes.

| | $/month |
|---|---|
| Scenario A | 590.80 |
| less ECS instances | -234.33 |
| less ECS EBS | -8.64 |
| **Total** | **≈ 347.83** |

Everything else continues billing. Scaling ECS down removes under a third of
the monthly cost; the NAT gateway, ALB, EC2 instances, and RDS are unaffected.

## Scenario C: apply, measure, destroy

The intended lifecycle. Hourly burn with the full stack up:

| Component | $/hour |
|-----------|--------|
| ECS, 3x `c6i.large` | 0.3210 |
| NAT gateway | 0.0620 |
| EC2 apps, 3x `c6i.large` | 0.3210 |
| RDS `db.m6g.large` | 0.2210 |
| ALB | 0.0243 |
| Public IPv4, 4 addresses | 0.0200 |
| EBS, 150 GB gp3 amortised | 0.0197 |
| **Total** | **≈ 0.9890** |

A full session (apply, push images, three 32-minute suites, teardown) is
roughly 8 hours of uptime:

| | $ |
|---|---|
| 8 hours of stack | 7.91 |
| Lambda, full sweep | 0.36 |
| CloudWatch Logs + NAT data | ~0.60 |
| **Per session** | **≈ 8.87** |

After `make destroy`, only the bootstrap state backend survives, well under
$0.50/month. `make destroy` also removes the ECR repositories, so the next
session needs `make push-images` again.

## Tearing down, and checking that it worked

```bash
make ecs-down            # scale ECS to zero first; the ASG otherwise fights the teardown
make destroy             # removes the whole stack, -auto-approve
make validate-teardown   # confirms it against AWS
```

`terraform destroy` reporting success only means the **state** is clean. A
resource created outside the stack, one removed from state, or a destroy that
failed halfway all keep billing while `terraform state list` looks empty.
`make validate-teardown` queries AWS directly for anything under the
`aws-perf-bench` prefix and exits non-zero while something billable is still
running:

```
=== compute ===
OK   EC2 instances: none
OK   Auto Scaling groups: none
OK   ECS clusters: none
OK   Lambda functions: none
=== network and storage ===
OK   Load balancers: none
OK   NAT gateways: none
OK   Elastic IPs: none
OK   RDS instances: none
OK   EBS volumes: none
```

The NAT gateway and Elastic IPs are the ones worth confirming by eye: they bill
hourly with nothing running on them, and are easy to leave behind.

**Download your results before destroying.** The load generator's S3 bucket is
declared with `force_destroy`, so the teardown empties and deletes it without
prompting, and every Artillery report still only in S3 goes with it. `make
loadgen-sync` pulls them down; `make validate-teardown` warns while the bucket
still holds objects, which is why it is worth running *before* the destroy as
well as after.

Nothing else is retained either: RDS uses `skip_final_snapshot`, the secrets
module uses a zero-day recovery window, and ECR repositories are `force_delete`.
A teardown is complete, not a pause.

## Lambda's marginal cost

Request volume comes from the Artillery phase definitions in
`benchmarks/suites/*/artillery/test-lambda.yml`:

| Suite | Duration | Requests per platform | Mean Lambda duration |
|-------|----------|-----------------------|----------------------|
| anilove | 33 min | 43,200 | 45 ms (estimate) |
| csv-processor | 27 min | 20,280 | 35.8 ms (CloudWatch, 2026-08-04) |
| thumbnail-generator | 33 min | 5,580 | ~143 ms (derived, see PAPER-SSCAD-2026.md) |
| **Total** | | **69,060** | |

At 1769 MB (1.73 GB, one full vCPU):

- Compute: ~3,400 GB-seconds x $0.0000166667 = **$0.06**
- Requests: 69,060 x $0.20/million = **$0.01**

**≈ $0.08 per full sweep**, before free tier. Raising Lambda from 1024 MB to
1769 MB is close to cost-neutral for CPU-bound work: memory rises 1.7x while
duration falls by roughly the same factor.


Lambda's per-request cost is a negligible share of the total. The fixed cost of
keeping three comparable platforms online accounts for nearly all of the bill.

## Reducing the bill

Ordered by saving:

1. **Destroy between sessions.** `make destroy` beats every other lever
   combined. The stack reapplies in minutes.
2. **`make ecs-down` when idle** (-$243/month) if the stack must stay up.
3. **NAT gateway** (-$46/month). It exists only so private subnets can reach
   ECR and the internet. Setting `enable_nat_gateway = false` breaks image
   pulls unless you add VPC endpoints for ECR, S3, CloudWatch Logs, and
   Secrets Manager. Interface endpoints have their own hourly charge, so the
   saving is partial and only pays off on a long-lived stack.
4. **Fewer AZs.** `az_count` defaults to 3; an ALB needs 2. Dropping to 2
   removes one public IPv4 (-$3.65/month) and shrinks the subnet footprint.
5. **Log retention.** `log_retention_days` is 14. Lower it if you export
   results to Grafana anyway.

Do not reduce cost by changing `ec2_instance_type`, `ecs_task_cpu`,
`ecs_task_memory`, or `lambda_memory_mb` in isolation. Those are the
comparison's controlled variables; changing one platform's resources
invalidates the benchmark. `make validate-fairness` checks for exactly this.

## Free tier

Free tier is close to irrelevant here. It covers 750 hours of
`t2.micro`/`t3.micro`, 750 hours of `db.t4g.micro` (which this stack no longer
uses, since a burstable database would make repeated runs non-comparable),
1M Lambda requests and
400,000 GB-seconds per month, but **`c6i.large` is not free-tier eligible**, so
the largest line item (79% of Scenario A) is billed in full. NAT gateway, ALB
and public IPv4 addresses are not covered either. Only RDS and part of the
Lambda usage fall inside the allowance.

Reverting to burstable types to reach the free tier would reintroduce the CPU
credit confound that the non-burstable choice exists to remove.

## Attributing cost per platform

Every taggable resource carries `Platform` (`ec2`, `ecs`, `lambda`, `shared`)
and `App` (`anilove`, `csv`, `thumbnail`, `shared`), applied through
`default_tags` in `terraform/providers.tf` and overridden per resource. See
`terraform/locals.tf`.

To break the bill down by compute model:

1. Open **Billing > Cost allocation tags**.
2. Activate `Platform`, `App`, `Project`, and `Component` as user-defined tags.
3. Wait up to 24 hours for them to appear in Cost Explorer.
4. Group by tag `Platform` in Cost Explorer.

`Platform = shared` marks resources the three platforms use in common (VPC,
NAT gateway, ALB, RDS, ECR). Their cost cannot be attributed to a single
platform, which is a property of the benchmark design rather than a tagging
gap: the comparison depends on all three platforms sharing that infrastructure.
Expect `shared` to be the largest slice.

## Caveats

- Estimates only. Actual charges depend on run frequency, log volume, image
  sizes, and data transfer. Check Cost Explorer for real numbers.
- Prices are Tokyo on-demand as of 2026-07-31, excluding tax.
- ALB LCU consumption is assumed at ~1 average. A heavy suite drives it
  higher; LCUs bill on the maximum of new connections, active connections,
  processed bytes, and rule evaluations.
- Public IPv4 charges for ALB nodes scale with AZ count.
- Data transfer out to the internet is not included. Artillery runs from your
  machine, so responses leave AWS and are billed above the monthly free
  allowance.
- `make destroy` does not remove `terraform/bootstrap/`. That is deliberate,
  and its residual cost is negligible.
