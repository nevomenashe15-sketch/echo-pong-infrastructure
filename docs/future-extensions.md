# Future extensions — what was deliberately not built

Scope discipline is a design decision, not an omission. Everything below was
considered and left out, with the trigger that would justify revisiting it.

The bar used throughout: **does this solve a problem echo-pong actually has?**
echo-pong is a small stateless Go HTTP service with four read-only endpoints,
one bearer token, a fixed and small client population, and a single AWS account.
A control that assumes a bigger system than that is complexity with no
corresponding risk reduction, and it still has to be reviewed, upgraded and
debugged forever.

---

## Networking and edge

### AWS Global Accelerator

Anycast IPs on the AWS backbone, with health-checked failover between regional
endpoints.

**Why it is out of scope.** It solves three problems, none of which exist here.
(1) Non-HTTP protocols — Global Accelerator carries raw TCP/UDP, but echo-pong
is HTTP and CloudFront already terminates at the edge. (2) Multi-region
active-active failover — there is one region. (3) Static IPs for client
allow-lists — the client population does not maintain firewall rules against
this service. On top of that it is roughly USD 18/month in fixed charges plus
per-GB data transfer *in addition to* CloudFront, for a request path that is
already anycast.

**Revisit when** a second active region exists and you need sub-minute failover
between them, or a regulated client requires a stable IP allow-list entry.

### AWS WAF Bot Control

A paid managed rule group that classifies traffic as human, verified bot, or
unverified automation.

**Why it is out of scope.** Bot Control's entire value is telling human traffic
from automated traffic — a distinction this API does not care about, because
**every** legitimate client is automated. Its output would be a categorisation
of 100% of traffic into one bucket. It also carries a per-request charge on top
of the base WAF cost (roughly USD 10/month per Web ACL plus about USD 1 per
million requests), which is a meaningful fraction of this stack's edge spend for
zero actionable signal.

The rate-based rule already covers the real threat model here: volumetric abuse
from a single source. `AWSManagedRulesAmazonIpReputationList` covers known-bad
origins.

**Revisit when** the service gains a browser-facing surface, or when WAF logs
show credential-stuffing patterns that the rate rule cannot distinguish from
legitimate burst traffic.

### AWS Shield Advanced

**Why it is out of scope.** USD 3,000/month with a one-year commitment. Shield
Standard is already on and free, and covers the L3/L4 volumetric attacks that
CloudFront absorbs anyway. Shield Advanced buys DDoS cost protection, a response
team, and L7 auto-mitigation — all of which price in against a revenue-bearing
service, which this is not.

**Revisit when** the service is revenue-bearing and an outage has a quantified
per-hour cost above the subscription.

### CloudFront origin failover / a second origin group

`CKV_AWS_310` flags this. There is exactly one origin: the app's ALB, itself
already multi-AZ. A second origin would have to be a second ALB in a second
region backed by a second cluster — which is the multi-region item below, not a
CloudFront setting.

**Revisit when** a second region exists.

### Geo restriction

`restriction_type = "none"`, and `CKV_AWS_374` flags it. The client population
is not known to be geographically bounded, and a geo block that is wrong is an
outage for a legitimate user with no error message explaining it.

**Revisit when** you have data showing legitimate traffic comes from a bounded
set of countries.

---

## Accounts and organisation

### Multi-account / AWS Organizations account vending

One account per environment, provisioned through Control Tower or an
Organizations-based vending pipeline, with SCPs at the OU level.

**Why it is out of scope.** This is the single biggest thing not built, and it
is a real trade. A shared account means dev and prod share an IAM namespace, a
service-quota pool, and a blast radius. The design compensates within the
account: separate state files, separate CMKs per purpose, non-overlapping VPC
CIDRs (`10.20.0.0/16` vs `10.10.0.0/16`) chosen so the two can be peered later
without renumbering, a `manage_account_globals` flag so exactly one root module
owns the shared singletons, and IAM roles whose trust policies pin exact repos
and refs.

What it does *not* compensate for: an SCP is the only control that a
sufficiently privileged in-account principal cannot route around, and
`echo-pong-gh-tf-apply` is privileged. Its explicit `Deny` statements are the
in-account approximation of an SCP, and they live in the same policy the role
carries — so a change to that policy is a change to its own guardrail.

**Revisit when** more than one team shares the account, when a compliance regime
requires environment isolation at the account boundary, or when a service quota
in one environment starts throttling the other. The migration path is
non-trivial: cross-account ECR replication (below) becomes mandatory, the
GitHub OIDC provider must be created per account, and the state bucket policy
grows cross-account principals.

### Permissions boundaries on the GitHub roles

`modules/iam-github-oidc/roles.tf` deliberately sets none. A boundary is the
right control in a multi-team account where many principals can create roles.
Here the five federated roles are the only federated principals, and each
already carries an explicit `Deny` for the account blast radius — a boundary
would duplicate that in a second place to keep in sync, and drift between the
two is worse than either alone.

**Revisit when** the account has principals outside this repository's control
that can create IAM roles.

---

## Container supply chain

### Cross-region ECR replication

`aws_ecr_replication_configuration`, which is **registry-scoped** and therefore
account-global.

**Why it is out of scope.** There is one region. Replication would produce a
second copy of every image in a region nothing pulls from, at USD 0.10/GB-month
plus cross-region transfer on every push. It is also a registry-level setting,
which means it sits outside a single environment's ownership boundary — the same
reason enhanced scanning was rejected below.

**Revisit when** a second region runs workloads (making it a latency and
availability requirement for image pulls), or when the estate splits into
multiple accounts and a shared registry stops being free.

### Amazon Inspector enhanced scanning

`aws_ecr_registry_scanning_configuration` with `scanType = "ENHANCED"`.

**Why it is out of scope.** It is configured at **registry** scope, is
account-global, and implicitly enables Amazon Inspector for the whole account —
a side effect well outside this repository's ownership boundary, and one that
bills per-image continuously rather than per-scan. Basic scan-on-push is
self-contained and gates the promotion step, which is what the pipeline actually
needs.

**Revisit when** you need continuous re-scanning of already-pushed images
against newly published CVEs (the genuine gap in scan-on-push), *and* the
account owner is willing to accept account-wide Inspector. Upgrading is a
one-resource change.

### Per-environment ECR repositories

`echo-pong-dev` / `echo-pong-prod` instead of one shared pair.

**Why it is out of scope.** It breaks the property the promotion flow exists to
provide — see `docs/architecture.md` §9. A digest is only meaningful within one
repository path.

**Revisit when** the estate splits into separate AWS accounts, at which point
cross-account pull grants or replication become necessary anyway and the single
registry stops being the simpler option.

### GitOps-aware image garbage collection

The ECR lifecycle policies are blanket and time/count-based because a lifecycle
policy has no knowledge of what `echo-pong-gitops` still references — it cannot
tell a digest pinned in a live Helm values file from an abandoned one. The
retention counts (30 releases, 10 candidates) are deliberately generous for that
reason.

**What would be built instead:** a scheduled job that reads the pinned digests
out of `echo-pong-gitops`, diffs them against the candidate digests in ECR, and
deletes only the difference — with a floor so a rollback horizon always survives.
**Documented, not built.**

**Revisit when** ECR storage cost becomes visible (it is well under USD 1/month
today) or when the release cadence makes 30 releases a short window.

### Image signing (cosign / Sigstore) and admission verification

Sign on promotion, verify with a policy controller in-cluster.

**Why it is out of scope.** The controls already in place cover the realistic
threat: immutable tags on both repositories, a single writer role pinned to
`refs/heads/main` and `refs/tags/v*` of the app repo, an optional
`job_workflow_ref` claim pinning which reusable workflow may drive it, and
digest pinning in the GitOps repo. Signing adds a key to manage, a verification
policy to keep in sync, and a new way for a deploy to fail closed.

**Revisit when** images come from more than one build system, or when a
third party consumes them.

---

## Cluster

### EBS CSI driver

Deliberately absent from `modules/eks/addons.tf`, which lists four add-ons:
`vpc-cni`, `kube-proxy`, `coredns`, `eks-pod-identity-agent`.

**Why it is out of scope.** echo-pong is stateless. It reads one secret from a
projected file and serves HTTP. There are no PersistentVolumeClaims, so the
driver would be a controller, a DaemonSet, an IAM role and a StorageClass that
exist to support zero volumes — plus a component in the upgrade path of every
cluster version bump.

**Revisit the day a workload with a PVC arrives.** It is an
`aws_eks_addon` block plus a Pod Identity role, and it is the first thing to add.

### EFS CSI driver, FSx, any shared filesystem

Same reasoning, one step further out. No workload needs shared state.

### Cluster Autoscaler

Karpenter is the capacity mechanism. Running both means two controllers with
opinions about node count.

### Service mesh (App Mesh, Istio, Linkerd)

**Why it is out of scope.** A mesh buys mTLS between services, traffic shifting,
and per-hop observability. There is **one** service. Traffic goes
CloudFront → ALB → pod, and there are no service-to-service calls to encrypt,
shift or trace.

**Revisit when** there is a second service in the cluster that the first one
calls.

### Managed Prometheus / Grafana, OpenTelemetry collectors

Not built here, and mostly not this repository's boundary anyway — observability
add-ons are Kubernetes objects and belong in `echo-pong-gitops`. What this repo
does provide is the raw AWS-side signal: control-plane logs (all five types),
VPC flow logs, CloudFront access logs in Parquet, WAF logs with redacted
headers, and CloudWatch metrics on every WAF rule.

**Revisit when** the GitOps repo is ready to own a monitoring stack; the AWS-side
prerequisite would be an AMP workspace plus a Pod Identity role, which is a small
addition to `modules/iam-pod-identity`.

### Private-only Kubernetes API endpoint

`enable_public_access = true` today, CIDR-restricted, with `0.0.0.0/0` rejected
by module validation. Turning the public endpoint off is stricter, but it means
GitHub-hosted runners can no longer reach the API and break-glass access needs a
bastion or VPN.

**Revisit when** CI moves to self-hosted runners inside the VPC, or when a VPN
path to the cluster exists.

### IRSA roles

The cluster's IAM OIDC provider **is** created (`enable_irsa_oidc_provider`
defaults to `true`) but no IRSA role is instantiated. It exists so that if a
controller version turns out to lack Pod Identity support, adding an IRSA role
is a self-contained change in `modules/iam-pod-identity` rather than a cluster
reconfiguration. Double-instantiating would mean two live credential paths per
controller and no way to tell from CloudTrail which one a request used.

**Revisit only if** a controller upgrade drops Pod Identity support.

---

## Secrets

### Automatic secret rotation

`modules/secrets-metadata` deliberately omits
`aws_secretsmanager_secret_rotation`, and `CKV2_AWS_57` flags it.

**Why it is out of scope.** Rotation needs a Lambda that knows how to roll the
token on both sides, and **echo-pong loads its secret once at startup with no
reload path**. Rotating the value without restarting every pod would break auth
for every request until the pods happen to cycle. Rotation is gated on an
application change, not an infrastructure one.

**Revisit when** the app supports re-reading its secret file — at which point
rotation is a Lambda plus one resource, and the ESO refresh interval becomes the
convergence window.

### Origin-verify value out of Terraform state

`random_password.origin_verify` puts a 64-character secret in plaintext in state.
The alternative — `generate_secret_string` on the Secrets Manager secret, never
read back, with the WAF rule updated out of band — removes the value from state
but introduces a component Terraform does not converge, which can silently drift
out of sync with CloudFront's custom header. That failure mode presents as a
**total outage**, since every request would be blocked by the default-deny
regional ACL.

The chosen trade is a self-contained converged configuration plus a hardened
state bucket. **Revisit when** state access needs to be granted to a principal
that should not hold this value.

---

## Operations

### Multi-region active-active

Two regions, both live, traffic split at the edge.

**Why it is out of scope.** It roughly doubles every fixed cost in
`docs/cost-estimate.md` (two EKS control planes, two NAT sets, two sets of VPC
endpoints, two node baselines) and forces decisions this design has been able to
avoid entirely: how the single ECR registry is reached from both, whether state
is regional or global, how the Secrets Manager value is replicated, and what
happens on a split-brain. For a stateless service with no availability SLO
beyond "the AZs it runs in", it is not justified.

**Revisit when** there is an availability SLO that a single region's AZ
redundancy cannot meet.

### Disaster recovery beyond state versioning

Today: the state bucket is versioned with 365-day noncurrent retention and
`prevent_destroy`; the lock table has point-in-time recovery and deletion
protection. There is no cross-region replication of state (`CKV_AWS_144`), no
tested restore runbook, and no backup of cluster state (there is nothing to back
up — every Kubernetes object is reconstructible from `echo-pong-gitops`).

**Revisit when** a compliance regime requires a tested RTO/RPO, at which point
S3 CRR on the state bucket is the first and cheapest addition.

### CloudTrail, GuardDuty, Security Hub, AWS Config

Not created here. These are account-level services, and creating them from an
environment root module would make one environment the owner of an account-wide
control — the same boundary problem as registry-scoped ECR settings. The
`echo-pong-gh-tf-apply` policy explicitly **denies** `cloudtrail:StopLogging`,
`DeleteTrail`, `UpdateTrail` and `guardduty:Delete*`/`Disassociate*`, on the
assumption that whatever owns the account has enabled them.

**Revisit when** the account-level ownership question is answered — realistically
at the same time as the multi-account item above.

### Atlantis / Terraform Cloud / a PR-driven apply runner

`echo-pong-gh-tf-plan` and `echo-pong-gh-tf-apply` exist and are correctly
scoped, and `echo-pong-workflows` owns the workflow files. A dedicated apply
runner would add drift detection and a plan-approval UI.

**Revisit when** more than one person applies this stack. Note the DynamoDB
locking constraint in `docs/architecture.md` §7 first: every consumer must agree
on the locking mechanism.

### Karpenter interruption queue

`modules/iam-pod-identity` has a `karpenter_interruption_queue_arn` variable and
a `dynamic "statement"` that grants SQS access when it is set. It is **not** set
today, because the NodePool that would use spot capacity lives in
`echo-pong-gitops` and the system node group is `ON_DEMAND` by module
validation.

**Revisit when** the GitOps repo introduces a spot NodePool. Without the queue,
Karpenter learns a spot node is gone when the kubelet stops reporting — roughly
two minutes after it could have started draining. The AWS side is an SQS queue
plus four EventBridge rules; the IAM grant is already written and waiting on the
ARN.

---

## Scanner findings deliberately left open

These are not future work; they are decisions. Recorded here so nobody "fixes"
them without reading the reasoning. Line references are to
`docs/cost-estimate.md`'s sibling scan output.

| Finding | Status |
|---|---|
| `CKV_AWS_38` / `CKV_AWS_39` / `AWS-0040` — EKS public endpoint enabled | Deliberate. CIDR-restricted, and the module **rejects** `0.0.0.0/0`. See "Private-only Kubernetes API endpoint" above. |
| `CKV_AWS_25` — SG allows ingress to port 3389 | False positive. The rule is `referenced_security_group_id` (control plane → kubelet, ports 1025–65535), not a CIDR. No internet path exists. |
| `CKV_AWS_86` / `AWS-0010` — CloudFront access logging disabled | False positive. Logging uses **standard logging v2** (`aws_cloudwatch_log_delivery*`), which the scanners do not yet recognise. The legacy `logging_config` block is deliberately unused because it requires bucket ACLs. |
| `CKV_AWS_158` / `AWS-0017` — WAF log groups not CMK-encrypted | Deliberate. Encrypting them requires granting `logs.<region>.amazonaws.com` on the secrets CMK, widening a key that also protects the app token. Both sensitive headers are redacted, so the log content does not warrant it. |
| `CKV_AWS_338` — log retention under one year | Deliberate. 7/30/90 days per environment; see the dev-vs-prod table. |
| `CKV_AWS_145` / `AWS-0132` — log buckets use SSE-S3, not KMS | Deliberate. The log delivery service would need `kms:GenerateDataKey` on the CMK; granting a broad service principal use of a key that also protects the app secret is a worse trade than SSE-S3 on logs containing no credentials. |
| `CKV_AWS_192` / `CKV2_AWS_47` — no explicit Log4Shell rule | False positive. `AWSManagedRulesKnownBadInputsRuleSet` **is** attached and contains the JNDI rules; the scanners look for a hand-written rule instead. |
| `CKV_AWS_305` — no `default_root_object` | Deliberate. The origin serves the docs page at `/` itself; setting it would make CloudFront rewrite `/` to `/index.html`, which the origin 404s. |
| `CKV_AWS_310` — no origin failover | See "CloudFront origin failover" above. |
| `CKV_AWS_374` — no geo restriction | See "Geo restriction" above. |
| `CKV2_AWS_57` — no automatic secret rotation | See "Automatic secret rotation" above. |
| `CKV_AWS_107/108/109/110/111/356` — IAM `Resource: "*"` | Reviewed individually. Every instance is either an API that takes no resource ARN (`sts:GetCallerIdentity`, `ecr:GetAuthorizationToken`, `ec2:Describe*`), a KMS **key policy** where `"*"` means "this key", or a `Deny` statement where `"*"` is the strict form. |
| `CKV_AWS_144` — no S3 cross-region replication | See "Disaster recovery" above. |
| `CKV2_AWS_62` — no S3 event notifications | Not applicable. Nothing consumes object-created events on these buckets. |
| `CKV2_AWS_64` — `bootstrap/` KMS key has no explicit policy | Accepted. The bootstrap state key relies on the default root-account policy plus IAM, because at the time it is created no role ARN exists to name in a policy. `modules/kms` does write explicit policies. |
| `CKV_AWS_18` — CloudFront log bucket has no access logging | Accepted. Logging the log bucket produces a recursive stream with no incident value; the **state** bucket, which is the sensitive one, does have access logging. |
| `CKV_AWS_259` — response header policy lacks HSTS | False positive. `strict_transport_security` is set with `access_control_max_age_sec = 63072000` and `include_subdomains = true`. |
| `AWS-0104` — unrestricted egress | Deliberate. Nodes need egress for image pulls, the EKS API and add-on registries; they sit in private subnets behind NAT with no inbound path. |
| `AWS-0342` — `iam:PassRole` present | Deliberate and conditioned on `iam:PassedToService` ∈ five named services. |

HSTS `preload` is left **off** on purpose: submitting to the preload list is
effectively irreversible on browser timescales and would commit every current
and future subdomain of the domain to HTTPS-only. That is not this stack's
decision to make unilaterally.
