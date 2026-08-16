# Monthly cost estimate

> ## ⚠️ THIS IS AN ESTIMATE, NOT A QUOTE
>
> Every number below is an approximation from published AWS on-demand list
> prices and a set of stated traffic assumptions. It has **not** been validated
> against a real bill.
>
> **Before relying on any figure here, re-derive it in the
> [AWS Pricing Calculator](https://calculator.aws/) and check it against AWS
> Cost Explorer for the account.** AWS prices change, vary by region, and are
> subject to free tiers, Savings Plans, EDP discounts and credits that this
> document knows nothing about.
>
> Prices are **list on-demand**, and the largest single source of error is the
> traffic assumption, not the unit price.

---

## Assumptions

**Region: `eu-central-1` (Frankfurt).** `var.aws_region` has no default in
either root module — it must be supplied. Both `terraform.tfvars.example` files
use `eu-central-1`, so that is what is priced here. The us-east-1 equivalents are
roughly 8–12% cheaper for compute and NAT; a us-east-1 deployment lands near the
low end of each range below.

Three resource classes are **always** in us-east-1 regardless of `aws_region`,
because AWS requires it: the CloudFront viewer certificate (free), the
`CLOUDFRONT`-scoped Web ACL, and the CloudFront standard-logging-v2 delivery
resources.

**Month = 730 hours.**

**Traffic:**

| | dev | prod |
|---|---|---|
| HTTPS requests / month | 1 M | 10 M |
| CloudFront data out | 5 GB | 100 GB |
| NAT-processed egress | 10 GB | 50 GB |
| CloudWatch Logs ingested | ~5 GB | ~60 GB |

`/ping`, `/pong`, `/health` and `/` all return small bodies and **caching is
disabled on every behaviour**, so CloudFront data-out ≈ origin data-out. There
is no cache-hit saving to model.

**Not included:** the Karpenter-provisioned application node capacity. Its
`NodePool` lives in `echo-pong-gitops`, so this repository cannot know the
instance families, limits or replica count. Only the system node group is
priced.

---

## What costs money at zero traffic

This is the number that matters for a demo or reference environment left
running.

| Resource | Idle charge | Where |
|---|---|---|
| **EKS control plane** | **USD 0.10/hr = 73.00/mo**, per cluster, flat | `modules/eks` |
| **NAT Gateway** | **USD 0.052/hr = 37.96/mo each**, plus per-GB processing on top | `modules/vpc` — dev 1, prod 3 |
| **VPC interface endpoints** | **USD 0.011/hr per endpoint per AZ.** 8 endpoints × AZ count. dev 16 ENI-hours = **128.48/mo**, prod 24 = **192.72/mo** | `modules/vpc` |
| **Elastic IPs** | **USD 0.005/hr = 3.65/mo per public IPv4 address**, including those attached to a NAT Gateway (charged since Feb 2024) | `modules/vpc` |
| **EC2 system nodes** | On-demand hourly, 24/7 — the group's `min_size` is 2 in both environments | `modules/eks` |
| **EBS root volumes** | USD 0.0952/GB-month, 50 GB per node | `modules/eks` |
| **KMS CMKs** | **USD 1.00/key/month.** dev 2, prod 3, bootstrap 1 | `modules/kms`, `bootstrap/` |
| **Secrets Manager** | **USD 0.40/secret/month.** 2 per environment (app token + origin-verify reference copy) | `modules/secrets-metadata`, `modules/cloudfront-waf` |
| **WAF Web ACL** | **USD 5.00/mo per Web ACL + USD 1.00/mo per rule.** Two ACLs per environment | `modules/cloudfront-waf` |
| **ALB** *(not created by this repo)* | **USD 0.027/hr = 19.71/mo** + LCU-hours + public IPv4 per AZ. Created by the AWS Load Balancer Controller from the Ingress in `echo-pong-gitops` — but it lands on **this account's bill** | — |
| **CloudFront** | **No idle charge.** Distributions cost nothing when they serve nothing | `modules/cloudfront-waf` |
| **ACM public certificates** | **Free**, both of them | `modules/route53-acm` |
| **Route 53 hosted zone** | **USD 0.50/mo — but NOT paid by this stack.** `modules/route53-acm` never creates a zone; it consumes `var.route53_zone_id`. Whoever owns the existing zone pays it. Queries resolved by an alias record to CloudFront are **free** | — |
| VPC, subnets, IGW, route tables, security groups, EKS access entries, Pod Identity associations, IAM roles/policies, ECR repositories (empty) | **Free** | — |

**The headline:** roughly **USD 320/month in dev and USD 700/month in prod
accrues with zero requests served.** Traffic-driven charges are a rounding error
next to the fixed floor at these volumes.

---

## dev — `envs/dev`

2 AZs, 1 NAT Gateway, 2 × `t4g.medium`, `manage_account_globals = false`.

| Service | Line item | Calculation | USD/mo |
|---|---|---|---:|
| **EKS** | Control plane | 730 × 0.10 | 73.00 |
| | Add-ons, access entries, Pod Identity | — | 0.00 |
| **EC2** | 2 × `t4g.medium` on-demand | 2 × 730 × 0.0376 | 54.90 |
| | 2 × 50 GB gp3 root | 100 × 0.0952 | 9.52 |
| **VPC / NAT** | 1 × NAT Gateway, hourly | 730 × 0.052 | 37.96 |
| | NAT data processing | 10 GB × 0.052 | 0.52 |
| | 1 × public IPv4 (NAT EIP) | 730 × 0.005 | 3.65 |
| | **8 interface endpoints × 2 AZ** | 16 × 730 × 0.011 | **128.48** |
| | Interface endpoint data | ~5 GB × 0.01 | 0.05 |
| | S3 gateway endpoint | — | 0.00 |
| **KMS** | 2 CMKs (`-eks`, `-secrets`) | 2 × 1.00 | 2.00 |
| | API requests | ~30 k × 0.03/10 k | 0.09 |
| **Secrets Manager** | 2 secrets | 2 × 0.40 | 0.80 |
| | API calls (ESO refresh) | ~50 k × 0.05/10 k | 0.25 |
| **WAF** | CLOUDFRONT ACL + 4 rules | 5.00 + 4 × 1.00 | 9.00 |
| | REGIONAL ACL + 1 rule | 5.00 + 1.00 | 6.00 |
| | Request charges | 2 × 1 M × 0.60/M | 1.20 |
| **CloudFront** | HTTPS requests | 1 M × 0.0120/10 k *(EU)* | 1.20 |
| | Data out | 5 GB × 0.085 | 0.43 |
| **CloudWatch Logs** | Ingest (control plane 5 types, flow logs `REJECT`, WAF) | ~5 GB × 0.63 | 3.15 |
| | Storage | ~1 GB-mo × 0.0324 | 0.03 |
| **S3** | CloudFront access logs (Parquet, 30-day expiry) | ~0.5 GB + requests | 0.30 |
| **Route 53** | Queries (alias → CloudFront are free) | — | 0.05 |
| **ACM** | 2 public certificates | — | 0.00 |
| | | **Subtotal — this repository** | **≈ 332** |
| *ALB* | *created by `echo-pong-gitops`* | *730 × 0.027 + ~2 LCU + 2 × IPv4* | *≈ 27* |
| *Karpenter app nodes* | *NodePool lives in `echo-pong-gitops`* | *unknown* | *variable* |
| | | **Total on the account** | **≈ 359+** |

## prod — `envs/prod`

3 AZs, 3 NAT Gateways, 3 × `m7g.large`, `manage_account_globals = true`,
Argo CD HA.

| Service | Line item | Calculation | USD/mo |
|---|---|---|---:|
| **EKS** | Control plane | 730 × 0.10 | 73.00 |
| **EC2** | 3 × `m7g.large` on-demand | 3 × 730 × 0.0918 | 201.04 |
| | 3 × 50 GB gp3 root | 150 × 0.0952 | 14.28 |
| **VPC / NAT** | 3 × NAT Gateway, hourly | 3 × 730 × 0.052 | 113.88 |
| | NAT data processing | 50 GB × 0.052 | 2.60 |
| | 3 × public IPv4 (NAT EIPs) | 3 × 730 × 0.005 | 10.95 |
| | **8 interface endpoints × 3 AZ** | 24 × 730 × 0.011 | **192.72** |
| | Interface endpoint data | ~20 GB × 0.01 | 0.20 |
| **KMS** | 3 CMKs (`-eks`, `-secrets`, `echo-pong-ecr`) | 3 × 1.00 | 3.00 |
| | API requests | ~150 k × 0.03/10 k | 0.45 |
| **Secrets Manager** | 2 secrets | 2 × 0.40 | 0.80 |
| | API calls | ~50 k × 0.05/10 k | 0.25 |
| **WAF** | CLOUDFRONT ACL + 4 rules | 5.00 + 4 × 1.00 | 9.00 |
| | REGIONAL ACL + 1 rule | 5.00 + 1.00 | 6.00 |
| | Request charges | 2 × 10 M × 0.60/M | 12.00 |
| **CloudFront** | HTTPS requests | 10 M × 0.0120/10 k *(EU)* | 12.00 |
| | Data out | 100 GB × 0.085 | 8.50 |
| **CloudWatch Logs** | Ingest (control plane 90 d, flow logs **`ALL`** 90 d, WAF) | ~60 GB × 0.63 | 37.80 |
| | Storage | ~35 GB-mo × 0.0324 | 1.13 |
| **ECR** | Storage, both repositories | ~5 GB × 0.10 | 0.50 |
| | Data transfer (in-region pulls) | — | 0.00 |
| **S3** | CloudFront access logs (90-day expiry, IA after 30) | ~4 GB + requests | 1.50 |
| **Route 53** | Queries | — | 0.50 |
| | | **Subtotal — this repository** | **≈ 702** |
| *ALB* | *created by `echo-pong-gitops`* | *730 × 0.027 + ~5 LCU + 3 × IPv4* | *≈ 32* |
| *Karpenter app nodes* | *NodePool lives in `echo-pong-gitops`* | *unknown* | *variable* |
| | | **Total on the account** | **≈ 734+** |

## Shared — `bootstrap/`

Applied once; not per-environment.

| Service | Line item | Calculation | USD/mo |
|---|---|---|---:|
| **KMS** | 1 CMK (`alias/echo-pong-tfstate`) | 1.00 | 1.00 |
| **S3** | State bucket + versions (365-day noncurrent retention) | < 0.1 GB | 0.05 |
| | Access-log bucket (90-day expiry) | < 0.1 GB | 0.05 |
| **DynamoDB** | Lock table, `PAY_PER_REQUEST` | a few thousand requests | 0.02 |
| | Point-in-time recovery | < 1 GB × 0.22 | 0.22 |
| | | **Total** | **≈ 1.35** |

## Estate total

| | USD/mo |
|---|---:|
| dev (this repo) | ≈ 332 |
| prod (this repo) | ≈ 702 |
| bootstrap | ≈ 1 |
| **Subtotal — resources this repository creates** | **≈ 1,035** |
| ALBs created by `echo-pong-gitops` (2) | ≈ 59 |
| Karpenter application capacity | variable |
| **Estate total** | **≈ 1,094 + app capacity** |

---

## The two findings worth acting on

### 1. VPC interface endpoints are the largest line item in dev

**USD 128/month in dev, USD 193/month in prod** — more than the NAT Gateways
they are partly meant to offset, and in dev more than the EKS control plane.

`modules/vpc` creates 8 interface endpoints (`ecr.api`, `ecr.dkr`, `sts`,
`secretsmanager`, `logs`, `eks-auth`, `ec2`, `elasticloadbalancing`), each with
one ENI **per private subnet**. The charge is per ENI-hour, so it scales with AZ
count, not with traffic.

The justification in the module is real — without them, ECR pulls and CloudWatch
writes traverse NAT and pay NAT data processing. But do the arithmetic:

- Endpoint cost: 16 ENI × USD 0.011/hr = **USD 128.48/mo** (dev).
- NAT data processing avoided: **USD 0.052/GB**.
- **Break-even ≈ 2,470 GB/month of endpoint-routed traffic in dev**
  (≈ 3,700 GB/mo in prod, where 24 ENIs cost USD 192.72).

At the assumed volumes, endpoint-routed traffic is single-digit GB. The
endpoints cost roughly **20× what they save** in dev, and the S3 gateway
endpoint — which handles the actual layer-blob download and is **free** — is
doing most of the useful work.

**Options, in order of how much they change:**

1. **Keep only `ecr.api`, `ecr.dkr` and `logs` in dev** (the three with real
   volume), drop the other five. Saves 5 × 2 × 730 × 0.011 = **USD 80.30/mo**.
   Requires a `var.interface_endpoints` list on `modules/vpc`.
2. **Drop interface endpoints entirely in dev**, keeping the free S3 gateway
   endpoint. Saves **USD 128.48/mo**. The cost is that `sts`, `secretsmanager`
   and `eks-auth` calls leave via NAT — a privacy/latency regression, not a
   functional one.
3. **Keep as-is in prod.** At prod's traffic and with a real availability
   argument (endpoint traffic does not depend on a NAT Gateway being healthy),
   USD 193/mo is defensible.

This is a genuine design question, not a bug — but it should be a *decision*,
and right now it is a default.

### 2. `traffic_type = "ALL"` flow logs dominate prod's variable cost

Prod's CloudWatch Logs line (**≈ USD 38/mo ingest**) is mostly VPC flow logs at
`ALL` with 90-day retention, and it scales linearly with cluster chatter — pod-to-pod
traffic across a 3-AZ VPC CNI cluster generates a lot of flow records. At 3× the
assumed volume it becomes the third-largest line item.

If it grows: send flow logs to **S3** instead of CloudWatch Logs. S3 delivery is
roughly USD 0.05/GB against CloudWatch's USD 0.63/GB ingest — about **12× cheaper**
— and Athena queries it fine for the forensic use case the `ALL` setting exists
for. The trade is losing CloudWatch Logs Insights and metric filters. This is a
`log_destination_type` change in `modules/vpc` plus a bucket.

---

## Cheaper-dev options, ranked by saving

| Change | Saving/mo | Cost of the change |
|---|---:|---|
| Trim interface endpoints to 3 (see above) | 80 | A new module variable; `sts`/`secretsmanager` calls go via NAT |
| Drop all interface endpoints in dev | 128 | Same, more so |
| Stop the dev cluster outside working hours (~128 h/week of 168) | ~90 | EKS control plane still bills; only EC2 and some NAT usage stop. Needs a scheduler and conflicts with `min_size = 2` |
| 1-year Compute Savings Plan on the system node groups | ~28 % of 256 ≈ 72 | A one-year commitment across both environments |
| `t4g.small` instead of `t4g.medium` in dev | 27 | Halves system-node memory; CoreDNS + 3 controllers + Argo CD is tight |
| Reduce dev to 1 AZ | — | **Blocked.** `modules/vpc` validates `length(var.azs) >= 2` and EKS refuses a control plane in fewer than 2 |
| Delete the dev environment when idle | 332 | `terraform destroy`; ~25 min to rebuild, plus a full Argo CD sync |

The single largest structural saving would be **not running a permanent dev
cluster** — but that trades against the entire purpose of the dev environment in
this design, which is to run the WAF managed rule groups in `count` mode
permanently and surface false positives before prod promotes a group to `block`.

---

## Unit prices used

`eu-central-1`, list on-demand, no free tier, no commitments.

| Item | Price |
|---|---|
| EKS control plane | USD 0.10 / cluster-hour |
| `t4g.medium` | USD 0.0376 / hr |
| `m7g.large` | USD 0.0918 / hr |
| EBS gp3 storage | USD 0.0952 / GB-month |
| NAT Gateway | USD 0.052 / hr + USD 0.052 / GB processed |
| VPC interface endpoint | USD 0.011 / hr / AZ + USD 0.01 / GB |
| VPC gateway endpoint (S3) | free |
| Public IPv4 address | USD 0.005 / hr |
| KMS CMK | USD 1.00 / key-month |
| KMS requests | USD 0.03 / 10,000 |
| Secrets Manager | USD 0.40 / secret-month + USD 0.05 / 10,000 API calls |
| WAF Web ACL | USD 5.00 / month |
| WAF rule (incl. each managed rule group) | USD 1.00 / month |
| WAF requests | USD 0.60 / million |
| CloudFront data out (EU) | USD 0.085 / GB, first 10 TB |
| CloudFront HTTPS requests (EU) | USD 0.0120 / 10,000 |
| CloudWatch Logs ingest | USD 0.63 / GB |
| CloudWatch Logs storage | USD 0.0324 / GB-month |
| S3 Standard | USD 0.0245 / GB-month |
| ECR storage | USD 0.10 / GB-month |
| DynamoDB on-demand write | USD 1.4135 / million WRU |
| DynamoDB PITR | USD 0.22 / GB-month |
| ALB | USD 0.027 / hr + USD 0.008 / LCU-hour |
| Route 53 hosted zone | USD 0.50 / month *(not paid by this stack)* |
| Route 53 standard queries | USD 0.40 / million *(alias-to-CloudFront free)* |
| ACM public certificate | free |

CloudFront's perpetual free tier (1 TB out, 10 M HTTPS requests per month) would
absorb dev's traffic entirely and most of prod's. It is **not** applied above —
the estimate is deliberately conservative on the traffic-driven lines, because
they are the smallest and least certain part of the total.
