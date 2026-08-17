# Cost estimate

What this stack costs to run in **ap-northeast-1 (Tokyo)**, and which parts
dominate the bill.

Summary: a full benchmark sweep across all three suites consumes about **$0.04**
of Lambda compute, and one apply-measure-destroy session costs about **$10.33**.
Leaving the same stack running for a month would cost about **$896**, because
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
| EC2 `c6i.xlarge` (load generator) | $0.2140 / hour |
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

`c6i.xlarge` is the one derived figure: on-demand pricing is linear in size
within a family, so it is exactly twice `c6i.large`.

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
- 1 load generator (`c6i.xlarge`, public subnet, 20 GB gp3) plus an S3 bucket for
  its reports, from `enable_loadgen = true`. It is in-region because a
  workstation uplink cannot supply the measured phase rates, and a saturated
  generator degrades all three platforms unevenly rather than failing cleanly
- 6 ECR images (3 apps x EC2/ECS + Lambda variants), 2 secrets, 9 log groups

Both EC2 apps and ECS container instances sit in **private** subnets, so all
their egress (package downloads) passes through the NAT gateway. ECR image
layers do not: an S3 gateway endpoint routes them off the NAT, which is free and
also speeds up every bring-up.

Set `budget_alert_emails` to be told when a stack outlives its session. The
threshold is `monthly_budget_usd` (default 50), alerting at 50% actual and 100%
forecast.

## Scenario A: everything left running, 730 hours

The ECS ASG defaults to 1 instance; `make ecs-up` scales it to 3. This table
uses 3, the state an actual benchmark runs in.

| Line item | Calculation | $/month |
|-----------|-------------|---------|
| ECS instances, 3x `c6i.large` | 3 x 730 x $0.1070 | 234.33 |
| EC2 apps, 3x `c6i.large` | 3 x 730 x $0.1070 | 234.33 |
| RDS instance `db.m6g.large` | 730 x $0.221 | 161.33 |
| Load generator, 1x `c6i.xlarge` | 730 x $0.2140 | 156.22 |
| NAT gateway hours | 730 x $0.062 | 45.26 |
| Public IPv4, 3 ALB nodes + 1 NAT + 1 load generator | 5 x 730 x $0.005 | 18.25 |
| ALB hours | 730 x $0.0243 | 17.74 |
| ECS EBS, 3x 30 GB gp3 | 90 x $0.096 | 8.64 |
| ALB LCU (assume ~1 average) | 730 x $0.008 | 5.84 |
| EC2 EBS, 3x 20 GB gp3 | 60 x $0.096 | 5.76 |
| RDS storage | 20 x $0.138 | 2.76 |
| Load generator EBS, 20 GB gp3 | 20 x $0.096 | 1.92 |
| CloudWatch Logs (assume ~2 GB) | 2 x $0.76 | 1.52 |
| Secrets Manager, 2 secrets | 2 x $0.40 | 0.80 |
| NAT data processing (assume ~10 GB) | 10 x $0.062 | 0.62 |
| ECR storage (assume ~2.5 GB) | 2.5 x $0.10 | 0.25 |
| S3 + DynamoDB state backend | negligible | 0.10 |
| Lambda | idle, no invocations | 0.00 |
| **Total** | | **≈ 895.67** |

Instance hours — the six app hosts plus the load generator — are 70% of the
bill, and the non-burstable database another 18%. Hourly billing on hardware
that is idle between runs is what makes an always-on stack expensive; see
Scenario C.

Rows marked "assume" depend on how much you actually run; the rest are fixed
by the stack's shape.

## Scenario B: ECS scaled to zero between runs

`make ecs-down` sets the ASG to 0, terminating the instances and their volumes.

| | $/month |
|---|---|
| Scenario A | 895.67 |
| less ECS instances | -234.33 |
| less ECS EBS | -8.64 |
| **Total** | **≈ 652.70** |

Everything else continues billing. Scaling ECS down removes just over a quarter
of the monthly cost; the NAT gateway, ALB, EC2 instances, RDS, and the load
generator are unaffected.

## Scenario C: apply, measure, destroy

The intended lifecycle. Hourly burn with the full stack up:

| Component | $/hour |
|-----------|--------|
| ECS, 3x `c6i.large` | 0.3210 |
| EC2 apps, 3x `c6i.large` | 0.3210 |
| RDS `db.m6g.large` | 0.2210 |
| Load generator, `c6i.xlarge` | 0.2140 |
| NAT gateway | 0.0620 |
| Public IPv4, 5 addresses | 0.0250 |
| ALB | 0.0243 |
| EBS, 170 GB gp3 amortised | 0.0224 |
| **Total** | **≈ 1.2107** |

A full session (apply, push images, the three suites, teardown) is roughly
8 hours of uptime:

| | $ |
|---|---|
| 8 hours of stack | 9.69 |
| Lambda, full sweep | 0.04 |
| CloudWatch Logs + NAT data | ~0.60 |
| **Per session** | **≈ 10.33** |

Only 52.5 minutes of those 8 hours is load: each suite runs a five-phase,
17.5-minute schedule, and the three can overlap. The rest is `apply`, the image
build and push, `ecs-up`, the validators, `db-reset` between repetitions,
`capture-*` before the stack comes down, and the teardown itself — and the
whole stack bills throughout.

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

All three suites now run the same five-phase schedule: 120 + 150 + 150 + 480 +
150 = 1050 s, so 17.5 minutes per platform. AniLove issues five requests per
arrival; CSV and Thumbnail one.

| Suite | Arrivals | Requests per platform | Mean Lambda `Duration` |
|-------|----------|-----------------------|------------------------|
| anilove | 3,840 | 19,200 | 6.19 ms (pilot 20260810-054832, CloudWatch) |
| csv-processor | 13,200 | 13,200 | 35.8 ms (CloudWatch, 2026-08-04) |
| thumbnail-generator | 4,500 | 4,500 | 129.0 ms (pilot 20260808-183300, CloudWatch) |
| **Total** | | **36,900** | |

Billing follows CloudWatch `Duration`, not the in-app timer: a concurrency slot
is held for the whole invocation. At 1769 MB (1.7275 GB, one full vCPU):

- Compute: 19,200 x 6.19 ms + 13,200 x 35.8 ms + 4,500 x 129.0 ms = 1,172
  function-seconds, x 1.7275 GB = ~2,024 GB-seconds x $0.0000166667 = **$0.03**
- Requests: 36,900 x $0.20/million = **$0.01**

**≈ $0.04 per full sweep**, before free tier, so **≈ $0.53** for the whole
39-run campaign (13 sweeps). Raising Lambda from 1024 MB to 1769 MB is close to
cost-neutral for CPU-bound work: memory rises 1.7x while duration falls by
roughly the same factor.


Lambda's per-request cost is a negligible share of the total. The fixed cost of
keeping three comparable platforms online accounts for nearly all of the bill.

## Reducing the bill

Ordered by saving:

1. **Destroy between sessions.** `make destroy` beats every other lever
   combined. The stack reapplies in minutes.
2. **`make ecs-down` when idle** (-$243/month) if the stack must stay up.
3. **`enable_loadgen = false` between campaigns** (-$162/month, instance plus
   its volume and public IPv4). The generator
   is only needed while load is running, but it bills like any other instance.
   Do not switch it off *during* a campaign: a workstation cannot supply the
   phase rates, and a saturated generator biases all three platforms.
4. **NAT gateway** (-$46/month). It exists only so private subnets can reach
   ECR and the internet. Setting `enable_nat_gateway = false` breaks image
   pulls unless you add VPC endpoints for ECR, S3, CloudWatch Logs, and
   Secrets Manager. Interface endpoints have their own hourly charge, so the
   saving is partial and only pays off on a long-lived stack.
5. **Fewer AZs.** `modules/network` takes `az_count`, default 3; an ALB needs 2.
   Dropping to 2 removes one public IPv4 (-$3.65/month) and shrinks the subnet
   footprint. The root stack does not pass this variable through, so lowering it
   means editing the `module "network"` block in `terraform/main.tf`, not
   `terraform.tfvars`. Compute placement is unaffected either way:
   `pin_compute_az` already confines it to one zone.
6. **Log retention.** `log_retention_days` is 14. Lower it if you export
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
the largest line item (70% of Scenario A) is billed in full. NAT gateway, ALB
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
- Data transfer is not included. Load runs from the in-region generator, so
  request and response bodies stay inside ap-northeast-1 and cross no NAT
  gateway; what leaves AWS is only the report download at the end of a run.
  Running Artillery from your workstation instead would put every response on
  the internet egress meter — and could not supply the phase rates anyway.
- `make destroy` does not remove `terraform/bootstrap/`. That is deliberate,
  and its residual cost is negligible.
