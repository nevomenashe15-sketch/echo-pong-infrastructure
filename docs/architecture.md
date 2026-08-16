# Architecture

How the echo-pong AWS estate is put together, what each module owns, and where
this repository's authority stops.

Everything below is read off the `.tf` files in this repository. Where a number
appears, it is the value actually in the code, and the file it came from is
named.

---

## 1. Request flow

```
                        client
                          │
                          │  HTTPS (TLS 1.2+, sni-only)
                          ▼
              ┌───────────────────────┐
              │  Route 53             │   envs/*/dns.tf
              │  A + AAAA alias       │   apex_a / apex_aaaa -> distribution
              └───────────┬───────────┘
                          ▼
              ┌───────────────────────┐
              │  WAFv2  scope=CLOUDFRONT  (us-east-1)     │
              │  3 managed groups + RateLimitPerIp        │
              │  modules/cloudfront-waf/waf-cloudfront.tf │
              └───────────┬───────────────────────────────┘
                          ▼
              ┌───────────────────────────────────────────┐
              │  CloudFront distribution                  │
              │  modules/cloudfront-waf/main.tf           │
              │  viewer cert: us-east-1 ACM               │
              │  adds header x-echo-pong-origin-verify    │
              └───────────┬───────────────────────────────┘
                          │
                          │  HTTPS, origin_protocol_policy = "https-only"
                          │  origin_ssl_protocols = ["TLSv1.2"]
                          │  origin = origin.<domain>   (NOT created here)
                          ▼
              ┌───────────────────────────────────────────┐
              │  WAFv2  scope=REGIONAL                    │
              │  default_action = BLOCK 403               │
              │  one rule: byte-match EXACTLY on the      │
              │  origin-verify header value               │
              │  modules/cloudfront-waf/waf-regional.tf   │
              └───────────┬───────────────────────────────┘
                          ▼
              ┌───────────────────────────────────────────┐
              │  ALB   ***NOT OWNED BY THIS REPOSITORY*** │
              │  created by the AWS Load Balancer         │
              │  Controller from the Ingress in           │
              │  echo-pong-gitops                         │
              │  origin cert: regional ACM                │
              └───────────┬───────────────────────────────┘
                          │  target-type: ip
                          ▼
                     echo-pong pod IPs
                     (private subnets, VPC CNI)
```

### What each hop actually enforces

| Hop | Control | Where it is declared |
|---|---|---|
| Route 53 → CloudFront | Alias A + AAAA, `evaluate_target_health = false` | `envs/*/dns.tf` |
| Viewer TLS | `TLSv1.2_2021`, `sni-only` | `modules/cloudfront-waf/main.tf` |
| Edge WAF | CommonRuleSet, KnownBadInputs, AmazonIpReputation, rate limit | `waf-cloudfront.tf` |
| Method restriction | `GET`/`HEAD` only on **every** behaviour including `/` | `main.tf`, `local.read_only_methods` |
| Header forwarding | `Authorization` forwarded on `/ping*` and `/pong*` only | `policies.tf`, `origin_request_policy.authenticated` |
| Caching | disabled everywhere (`default_ttl = min_ttl = max_ttl = 0`) | `policies.tf`, `cache_policy.disabled` |
| Origin TLS | CloudFront→ALB is a real TLS session, second certificate | `modules/route53-acm/main.tf` |
| Origin verification | REGIONAL WAF default-BLOCK + exact byte match on a 64-char alphanumeric secret | `waf-regional.tf`, `origin-verify.tf` |

### Two certificates, not one

`modules/route53-acm` issues two ACM certificates because there are two
independent TLS terminations:

1. **viewer** — `var.domain_name`, issued through the `aws.useast1` alias.
   CloudFront only accepts us-east-1 certificates. Hard AWS constraint.
2. **origin** — `origin.<domain_name>`, issued in `var.aws_region`. An ALB can
   only use a certificate from its own region.

Both are DNS-validated against the pre-existing hosted zone, with
`allow_overwrite = true` on the validation records so a re-issue does not
collide with the record from the previous issuance.

### The 502 window is by design

`origin.<domain>` is never created by Terraform. It resolves only once
`echo-pong-gitops` has an Ingress carrying
`external-dns.alpha.kubernetes.io/hostname` and external-dns has published it.
Between `terraform apply` and the first successful Argo CD sync, CloudFront has
no origin and returns 502. That is the correct, visible failure mode — not a
bug to paper over.

---

## 2. Module graph

```
                         modules/kms  (instantiated 2-3x per env)
                         ├── kms_eks      -> flow log group, control-plane log
                         │                   group, EKS secret envelope key
                         ├── kms_secrets  -> Secrets Manager (app token +
                         │                   origin-verify reference copy)
                         └── kms_ecr      -> ECR layer encryption
                                             (prod only: manage_account_globals)

  modules/vpc  ◄── kms_eks.key_arn
      │
      │ vpc_id, private_subnet_ids
      ▼
  modules/eks  ◄── kms_eks.key_arn
      │
      ├── cluster_name, cluster_arn ──────► modules/iam-pod-identity ◄── kms_secrets
      │                                          │
      │   karpenter_node_role_arn ───────────────┘
      │
      ├── system_node_role_arn, karpenter_node_role_arn ──► modules/ecr (prod only)
      │
      └── cluster_endpoint / CA ──► helm provider ──► modules/argocd-bootstrap

  modules/route53-acm  (needs aws + aws.useast1)
      │
      │ viewer_certificate_arn, origin_fqdn
      ▼
  modules/cloudfront-waf  (needs aws + aws.useast1)  ◄── kms_secrets
      │
      │ distribution_domain_name / hosted_zone_id
      ▼
  envs/*/dns.tf   aws_route53_record.apex_a / apex_aaaa

  modules/iam-github-oidc (prod only)
      │ tf_apply_role_arn ──► modules/eks cluster_admin_principal_arns
      │ ecr_release_role_arn, ci_validation_role_arn ──► modules/ecr

  modules/secrets-metadata  ◄── kms_secrets, ◄── pod_identity.external_secrets_role_arn

  bootstrap/   (separate state, no backend block, applied by hand first)
```

### Edges that exist for a reason, and edges that deliberately do not

**`modules/cloudfront-waf` references the ALB but never creates it.**
It takes `origin_fqdn` as a plain string and emits `regional_web_acl_arn` as an
output. There is no `aws_wafv2_web_acl_association` in the module, because the
ALB does not exist at apply time. The controller performs the association from
the `alb.ingress.kubernetes.io/wafv2-acl-arn` annotation.

**The alias record lives in the root module, not in `modules/route53-acm`.**
`cloudfront-waf` needs the viewer certificate *from* `route53-acm`; the alias
record needs the distribution domain *from* `cloudfront-waf`. Putting the record
inside `route53-acm` makes the two modules mutually dependent, and Terraform
rejects module-level cycles outright. The root module already sees both sides.

**`modules/iam-github-oidc` constructs ECR ARNs by string rather than reading
`module.ecr`.** `modules/ecr`'s repository policy needs the OIDC module's role
ARNs, so the OIDC module cannot depend on the ECR module's outputs. The ARNs are
built from `var.aws_region` + `local.account_id` instead.

**`modules/eks` creates an IRSA OIDC provider it does not use.**
`enable_irsa_oidc_provider` defaults to `true` and no IRSA role is instantiated
anywhere. It exists because it is the one prerequisite that cannot be added
quickly under incident pressure if a controller version turns out to lack Pod
Identity support.

---

## 3. Ownership boundary

### Terraform's last Kubernetes touch

`modules/argocd-bootstrap` installs the upstream `argo-cd` Helm chart
(pinned, `var.argocd_chart_version = "7.7.11"`) plus a vendored two-template
local chart containing:

- one `AppProject` named `echo-pong-<env>`, whose `sourceRepos` is a single
  entry — the `echo-pong-gitops` URL,
- one `Application` named `echo-pong-<env>-root`, pointing at
  `bootstrap/<env>` in `echo-pong-gitops`.

**That is the entire set. Terraform creates no other Kubernetes object, ever.**

The root `Application` deliberately carries **no**
`resources-finalizer.argocd.argoproj.io` finalizer. With it, deleting the
Application cascade-deletes every child Application and transitively the whole
cluster workload set — a `terraform destroy` or a careless `terraform state rm`
would take the platform down. Without it, deletion orphans the children:
workloads keep running unmanaged and can be re-adopted by recreating the
Application. Orphaned-but-running recovers in minutes; cascade-deleted does not.

`helm_release` is used rather than `kubernetes_manifest` because
`kubernetes_manifest` performs a server-side dry-run at **plan** time, which
fails whenever the cluster is unreachable — including on the first apply and on
every CI plan from a runner without cluster credentials.

### The boundary table

| Thing | This repo | `echo-pong-gitops` | `echo-pong-workflows` |
|---|---|---|---|
| VPC, subnets, NAT, endpoints, flow logs | ✅ | | |
| EKS cluster, system node group, core add-ons | ✅ | | |
| `vpc-cni`, `coredns`, `kube-proxy`, `eks-pod-identity-agent` | ✅ (`aws_eks_addon`) | | |
| AWS LB Controller, ESO, Karpenter — **IAM role** | ✅ | | |
| AWS LB Controller, ESO, Karpenter — **Helm install** | | ✅ | |
| Karpenter `NodePool` / `EC2NodeClass` | | ✅ | |
| Karpenter node IAM role + instance profile | ✅ | | |
| The app's `Ingress` | | ✅ | |
| **The app's ALB, listener, target group** | ❌ **never** | ✅ (via controller) | |
| `origin.<domain>` DNS record | ❌ **never** | ✅ (via external-dns) | |
| `<domain>` A/AAAA alias to CloudFront | ✅ | | |
| REGIONAL Web ACL (the object) | ✅ | | |
| REGIONAL Web ACL **association** to the ALB | ❌ | ✅ (annotation) | |
| Secrets Manager secret container | ✅ | | |
| Secrets Manager secret **value** | ❌ **never** | ❌ | ❌ (human, out of band) |
| `ExternalSecret` / `SecretStore` | | ✅ | |
| ECR repositories + lifecycle policies | ✅ (prod only) | | |
| Image build / push / digest promotion | | | ✅ |
| Argo CD install + one root Application | ✅ | | |
| Everything else in the cluster | | ✅ | |
| GitHub Actions IAM roles | ✅ (prod only) | | |
| GitHub Actions workflow files | | | ✅ |

### Why the ALB rule is the load-bearing one

If Terraform declared an `aws_lb`, two systems would hold write access to one
resource. The controller reconciles the ALB from the Ingress on every resync;
Terraform reasserts it on every apply. They would fight indefinitely, and the
observable symptom is intermittent listener/target-group churn that looks like
an AWS fault rather than a configuration one.

Terraform contributes exactly three things to that ALB: the IAM role the
controller assumes (`modules/iam-pod-identity/alb-controller.tf`), the regional
ACM certificate it attaches, and the regional Web ACL it associates. All three
are handed over as outputs, not as references.

### Secrets: nothing here ever holds the app's token

`modules/secrets-metadata` creates the `aws_secretsmanager_secret` and nothing
else. There is no `aws_secretsmanager_secret_version` in it and no
`secret_string` argument anywhere in the module. The value is set once by a
human via `aws secretsmanager put-secret-value`.

The secret's resource policy carries an explicit `Deny` on
`secretsmanager:PutSecretValue` and `UpdateSecret` for every principal that is
not tagged `SecretCustodian = "true"` — so even an over-broad identity policy
cannot write it programmatically.

External Secrets Operator is the only reader. The app pod itself holds **no AWS
identity at all**: ESO projects the value into a native Kubernetes Secret and
the app reads it from a file.

**One exception, stated plainly:** the CloudFront origin-verification value *is*
generated by Terraform (`random_password.origin_verify`, 64 alphanumeric chars)
and therefore **exists in plaintext in Terraform state**. `sensitive = true`
redacts CLI output only; it does nothing to the state file. That is accepted,
and the mitigation is that the state bucket is treated as a secret store: CMK
encryption, public access blocked, TLS enforced by bucket policy, an allow-list
Deny on every other principal, and S3 access logging to a separate bucket.

---

## 4. Cluster admin bootstrap

`modules/eks` sets `bootstrap_cluster_creator_admin_permissions = false`, so
the identity that runs the first apply gets **no** implicit cluster-admin. The
only path to cluster-admin is `var.cluster_admin_principal_arns`, which becomes
`aws_eks_access_entry` + `aws_eks_access_policy_association` resources.

Each root module builds that list from two sources:

```hcl
cluster_admin_principal_arns = concat(
  compact([
    var.manage_account_globals ? module.iam_github_oidc[0].tf_apply_role_arn : "",
  ]),
  var.extra_cluster_admin_principal_arns,
)
```

- In **`envs/prod`** the first element is `echo-pong-gh-tf-apply`. That covers
  CI applies but **not** the documented bootstrap sequence, which runs from a
  human's own credentials.
- In **`envs/dev`** `manage_account_globals` is `false`, so the first element is
  empty and `var.extra_cluster_admin_principal_arns` is the *only* source.

**`extra_cluster_admin_principal_arns` must therefore be populated in both
environments.** Leaving it empty in dev produces a cluster with zero
administrators: the `helm_release` for Argo CD fails with a Forbidden error and
no human can use `kubectl` either. It is listed in both
`terraform.tfvars.example` files.

---

## 5. IAM

### GitHub Actions federated roles (5, created by `envs/prod` only)

All five are created by `modules/iam-github-oidc`. Every trust policy pins
`token.actions.githubusercontent.com:aud` to `sts.amazonaws.com` with
`StringEquals`. No trust policy uses a wildcard repository. No role carries
`AdministratorAccess`.

| Role | Trust condition (`sub` / extra claims) | Purpose | Permissions scope |
|---|---|---|---|
| `echo-pong-gh-ci-validation` | `StringLike sub = repo:<owner>/{echo-pong,‑infrastructure,‑gitops,‑workflows}:*` — any ref of all four repos | fmt / lint / non-plan validation on PRs, including fork branches | `sts:GetCallerIdentity` + ECR metadata reads (`Describe*`, `List*`, `DescribeImageScanFindings`). No mutation anywhere. |
| `echo-pong-gh-ecr-release` | `StringLike sub = repo:<owner>/echo-pong:ref:refs/heads/main` **or** `refs/tags/v*`; optional `StringLike job_workflow_ref` when `release_job_workflow_ref` is set | push to quarantine, promote a digest into production | `ecr:GetAuthorizationToken` on `*` (AWS rejects any other resource) + push/pull/describe verbs scoped to the two repository ARNs. Explicitly **not** granted `BatchDeleteImage`, `DeleteRepository`, `PutLifecyclePolicy`, `SetRepositoryPolicy`, `PutImageTagMutability`. |
| `echo-pong-gh-tf-plan` | `StringLike sub = repo:<owner>/echo-pong-infrastructure:*` — any ref, because plan must run on PRs | `terraform plan` | `Describe*`/`List*`/`Get*` across 18 named services; state object read + DynamoDB lock item write + `kms:Decrypt` on the state key; a hard `Deny` on every mutating verb, carved out only for the state bucket and lock table via `ArnNotEquals` on `aws:ResourceArn`. |
| `echo-pong-gh-tf-apply` | `StringEquals sub = repo:<owner>/echo-pong-infrastructure:environment:production-infra` **AND** `StringEquals ref = refs/heads/main` **AND** `StringEquals repository = <owner>/echo-pong-infrastructure` | `terraform apply` on this stack | Broadest role in the repo, still not admin. Service-scoped `*` on 14 services; IAM limited to role/policy/instance-profile lifecycle (never users, keys, login profiles, MFA, SAML/OIDC providers); `iam:PassRole` conditioned on `iam:PassedToService` ∈ {eks, ec2, pods.eks, vpc-flow-logs, delivery.logs}; explicit `Deny` on Organizations, account settings, CloudTrail tampering, `kms:ScheduleKeyDeletion`, GuardDuty deletion, `ec2:DeleteFlowLogs`, and bucket-policy writes outside `echo-pong-*`. |
| `echo-pong-gh-bootstrap` | `StringEquals sub = repo:<owner>/echo-pong-infrastructure:environment:bootstrap` | one-time creation of the state backend and the OIDC provider itself | S3/DynamoDB/KMS for the backend; the **only** role permitted `iam:CreateOpenIDConnectProvider`; role/policy creation. Hard `Deny` on Organizations, account, IAM user/key creation, role/policy **deletion**, CloudTrail tampering, and all of `ec2:*`, `eks:*`, `cloudfront:*`, `rds:*`. |

The `tf-apply` trust policy deserves a note. `sub` is a *single* string, and
listing two values in one condition is an OR, not an AND. When a job runs inside
a GitHub Environment the sub is `repo:<owner>/<repo>:environment:<name>` and the
`ref:refs/heads/main` form is **not** also present — so "main AND environment"
cannot be expressed in `sub` alone. The AND is built from three separate claims
(`sub`, `ref`, `repository`) in one statement, which IAM evaluates conjunctively.

### EKS Pod Identity roles (3, created per environment)

All three share one trust policy (`modules/iam-pod-identity/main.tf`):
principal `pods.eks.amazonaws.com`, actions `sts:AssumeRole` + `sts:TagSession`,
and — the load-bearing line — `ArnEquals aws:SourceArn = <this cluster's ARN>`.
Without that condition the role is assumable on behalf of a pod in any cluster
in the account.

| Role | Bound to (ns/SA) | Purpose | Permissions scope |
|---|---|---|---|
| `echo-pong-<env>-alb-controller` | `kube-system/aws-load-balancer-controller` | create and own the app's ALB, listeners, target groups; attach the regional Web ACL | ELBv2 create/modify/delete gated on `aws:RequestTag`/`aws:ResourceTag` `elbv2.k8s.aws/cluster` being present; `RegisterTargets`/`DeregisterTargets` scoped to `targetgroup/*/*`; security-group creation gated on the same tag so it cannot mint untagged groups or delete ours; `wafv2:AssociateWebACL`; `iam:CreateServiceLinkedRole` conditioned on `elasticloadbalancing.amazonaws.com`. |
| `echo-pong-<env>-external-secrets` | `external-secrets/external-secrets` | read the app token and project it into a Kubernetes Secret | `GetSecretValue`, `DescribeSecret`, `ListSecretVersionIds` on an **explicit ARN list** (`var.secret_arns`), never a prefix wildcard; `kms:Decrypt` on the secrets CMK conditioned on `kms:ViaService = secretsmanager.<region>.amazonaws.com`; explicit `Deny` on every secret-mutating verb. |
| `echo-pong-<env>-karpenter-controller` | `karpenter/karpenter` | provision and reclaim node capacity | `RunInstances`/`CreateFleet`/`CreateLaunchTemplate` conditioned on `aws:RequestTag/kubernetes.io/cluster/<name> = owned`; `TerminateInstances`/`DeleteLaunchTemplate` conditioned on the `karpenter.sh/nodepool` tag existing **and** the cluster tag being `owned`, so it cannot terminate the system node group and deadlock itself; `iam:PassRole` scoped to exactly the Karpenter node role; instance-profile management scoped to this account. SQS interruption-queue grant is conditional on `karpenter_interruption_queue_arn` being set (it is not, today). |

The app's own ServiceAccount has **no** role. That is the point of the ESO
design: no AWS identity ever reaches application code.

### Why Pod Identity rather than IRSA

- The trust policy is a static service-principal policy that does not embed the
  cluster's OIDC issuer URL, so a cluster rebuild does not invalidate every role.
- The role ARN does not have to appear as a ServiceAccount annotation, which
  would force `echo-pong-gitops` to template an AWS account ID into its Helm
  values and couple the two repositories.
- The association is an AWS API object Terraform owns, rather than a Kubernetes
  annotation Argo CD owns.

The `eks-pod-identity-agent` add-on is load-bearing: without it every
`aws_eks_pod_identity_association` is inert and the controllers silently fall
back to the **node role**, which grants *more* permission than intended, not
less.

---

## 6. dev vs prod

Everything below is a real difference between `envs/dev` and `envs/prod`. Any
setting not listed here is identical in both.

| | `envs/dev` | `envs/prod` |
|---|---|---|
| **VPC CIDR** | `10.20.0.0/16` | `10.10.0.0/16` |
| **AZs** (example tfvars) | 2 — `eu-central-1a/b` | 3 — `eu-central-1a/b/c` |
| **Subnets** | 2 public /20 + 2 private /20 | 3 public /20 + 3 private /20 |
| **NAT strategy** | `single_nat_gateway = true` — **one** gateway for the whole VPC | `single_nat_gateway = false` — **one per AZ** |
| **NAT failure mode** | losing the gateway's AZ removes *all* private egress, image pulls included | an AZ failure leaves the surviving AZs with egress |
| **Flow logs** | `traffic_type = REJECT`, 7-day retention | `traffic_type = ALL`, 90-day retention |
| **Control-plane log retention** | 30 days | 90 days |
| **System node instance type** | `t4g.medium` | `m7g.large` |
| **System node sizing** | desired 2 / min 2 / **max 3** | desired 3 / min 2 / **max 6** |
| **Node disk** | 50 GB gp3, encrypted | 50 GB gp3, encrypted |
| **Argo CD** | `high_availability = false` — 1 replica each, bundled Redis | `high_availability = true` — 2 replicas each, `redis-ha` |
| **WAF rate limit** | 500 req / IP / 5 min | 2000 req / IP / 5 min |
| **WAF managed-group action** | all three groups `count`, **permanently** — dev exists to surface false positives | all three groups `count` *by default*, promoted to `block` one at a time after reading a full traffic cycle |
| **CloudFront log retention** | 30 days | 90 days |
| **Account-global singletons** | `manage_account_globals = false` | `manage_account_globals = true` — owns the OIDC provider, the 5 `echo-pong-gh-*` roles, and both ECR repositories |
| **GitOps root path** | `bootstrap/dev` | `bootstrap/prod` |
| **State key** | `dev/terraform.tfstate` | `prod/terraform.tfstate` |

Identical in both, worth noting because they are sometimes environment-varied
elsewhere: `kubernetes_version = "1.32"`, `price_class = "PriceClass_100"`,
`capacity_type = "ON_DEMAND"` (module-validated — spot interruption of the node
running the Karpenter controller can leave the cluster unable to provision its
own replacement), `enable_public_access = true` with a CIDR allow-list that the
module rejects `0.0.0.0/0` in, `rate_limit_action = "block"`,
`image_tag_mutability = "IMMUTABLE"`, `authentication_mode = "API"`.

### The WAF tuning workflow

Every managed rule group starts in `count`. A group switched straight to `block`
on day one will reject some proportion of legitimate traffic, and you find out
which proportion during an incident.

1. Run in `count`. WAF logging is on with `default_behavior = "DROP"` and a
   `KEEP` filter on `BLOCK` **and** `COUNT` actions, so the log contains exactly
   the requests that *would* have been blocked.
2. Read `<group>CountedRequests` in CloudWatch and the sampled requests for a
   full traffic cycle.
3. Tune with per-rule `rule_action_override` exclusions.
4. Flip **one** group at a time in `var.waf_rule_action_override`.

Do this in dev first — that is what the permanent-count posture in dev is for.

`waf_log_retention_days` defaults to 30 in both environments; the window has to
cover at least one traffic cycle plus review time.

### WAF log redaction

WAF logs are the opposite of CloudFront access logs: a WAF log record contains
request headers **by default**, because the whole point is to show what the rule
matched on. Both logging configurations
(`modules/cloudfront-waf/waf-logging.tf`) redact two headers:

- `authorization` — the bearer token the app authenticates with. Logging it
  would put live credentials in CloudWatch for every `/ping` and `/pong`,
  readable by anyone with `logs:GetLogEvents`.
- `x-echo-pong-origin-verify` — the CloudFront→ALB shared secret. Logging it in
  the regional ACL would defeat the entire origin-verification control, because
  the value is exactly what an attacker needs to bypass CloudFront.

CloudFront *access* logs need no equivalent control: the standard log format has
a fixed field set with no facility for arbitrary request headers, so
`Authorization` cannot appear in them. The `record_fields` allow-list in
`logging.tf` also omits `cs(Cookie)`.

---

## 7. State and bootstrap ordering

Three root modules, three independent states, one shared backend:

| Root | State key | Backend |
|---|---|---|
| `bootstrap/` | — | **none**, local state (it creates the backend) |
| `envs/prod/` | `prod/terraform.tfstate` | S3 + DynamoDB, via `-backend-config` |
| `envs/dev/` | `dev/terraform.tfstate` | same bucket, different key |

Explicit key paths, not workspace prefixes (`env:/dev/...`). Workspaces put both
environments in one state lineage and make it possible to apply prod's
configuration into dev's workspace by forgetting a `terraform workspace select`.
Separate directories make the environment a property of *where you are*, and
they allow dev and prod to genuinely diverge — which they do, in the 15 rows of
the table above.

**Apply order is `bootstrap/` → `envs/prod/` → `envs/dev/`.** Not a preference:
the GitHub OIDC provider, the five `echo-pong-gh-*` roles and the two ECR
repositories have literal, environment-agnostic names, and a single AWS account
hosts both environments. Exactly one root module may create them or the second
apply fails with `EntityAlreadyExists`. `envs/prod` owns them, gated on
`var.manage_account_globals`.

Three circular dependencies are broken by hand, once:

1. **The state backend** is itself Terraform-managed, so `bootstrap/` has no
   backend block and runs on local state.
2. **The OIDC provider** must exist before the roles that would create it are
   assumable.
3. **The state bucket policy** allow-lists role ARNs that do not exist until
   `envs/prod` has run — so `bootstrap/` is applied twice, with the principal
   lists empty the first time. The `DenyNonApprovedPrincipals` statement is
   wrapped in a `dynamic "statement"` guarded on the list being non-empty,
   because applying it with empty lists would lock everyone out.

And one more, per cluster: `enable_argocd = false` on the very first apply. The
`helm` provider authenticates against a cluster endpoint that does not exist
until `module.eks` has been created, so a plan that includes `helm_release`
fails before it can create the thing it needs. Two applies; thereafter one.

**DynamoDB, not S3 native locking.** `use_lockfile` requires Terraform ≥ 1.10 and
this repo is pinned `>= 1.9.0, < 2.0.0`. Mixing the two provides *no* mutual
exclusion at all, so DynamoDB stays until every consumer — local dev, CI
runners, whatever runs apply — is on ≥ 1.10.

---

## 8. Networking details worth knowing

**Subnetting** is deterministic and index-based: `cidrsubnet(vpc_cidr, 4, n)`
yields /20s, with `n = 0..az_count-1` public and `n = 8..` private. The gap keeps
the two classes visually distinct in route tables. There is no third
"intra"/database tier — the app is stateless with no RDS or ElastiCache
dependency, and an unused tier is three more route tables to review for no
benefit.

**One private route table per AZ even when `single_nat_gateway = true`**, so
flipping the flag is a route change rather than a subnet re-association.

**Both ECR interface endpoints *and* the S3 gateway endpoint are required.**
`ecr:GetAuthorizationToken` and `BatchGetImage` go to `ecr.api`; the layer
download is negotiated through `ecr.dkr` — but ECR returns a **presigned S3
URL** and the runtime fetches the actual blobs from S3. Without the S3 gateway
endpoint the layer pull falls back to the NAT Gateway and the interface
endpoints buy nothing. Eight interface endpoints are created: `ecr.api`,
`ecr.dkr`, `sts`, `secretsmanager`, `logs`, `eks-auth`, `ec2`,
`elasticloadbalancing`. See `docs/cost-estimate.md` — this is the single largest
line item in dev and it does not pay for itself at low traffic.

**The default security group is explicitly stripped to nothing.** AWS creates it
with an allow-all-from-self rule, it cannot be deleted, and leaving it
permissive is a standing finding in every CIS benchmark.

**`map_public_ip_on_launch = false` on both tiers.** The only things in a public
subnet are ALBs (which get addresses from the service) and NAT Gateways
(explicit EIP association).

**Nodes:** private subnets only, IMDSv2 required (`http_tokens = "required"`),
`http_put_response_hop_limit = 1` so a container on the host bridge network
cannot reach IMDS at all, encrypted gp3 root volumes, SSM Session Manager
instead of SSH (no key pair, no port 22, no bastion). The system node group
carries a `echo-pong.io/system=true:NoSchedule` taint so the app's pods cannot
silently turn it into the app's capacity and defeat the point of Karpenter.

**`ENABLE_PREFIX_DELEGATION = "true"` on the VPC CNI.** Without it an
`m7g.large` tops out at roughly 29 pods and burns ENIs.

**Control-plane ENIs go in the private subnets.** There is no reason for the
control plane's cross-account ENIs to sit in a subnet with an IGW route.

---

## 9. ECR: one registry pair, not one per environment

There is a single `echo-pong` repository and a single `echo-pong-quarantine`
repository for the whole estate.

The promotion flow only means something if the artifact that was scanned is
bit-identical to the artifact that runs. A digest is only meaningful within one
repository path, so per-environment repositories would force a re-push between
dev and prod — at which point "dev tested digest X" and "prod runs digest X"
become two claims about two different objects.

The blast-radius counter-argument is handled with IAM instead: only
`echo-pong-gh-ecr-release` can write, and its trust policy is pinned to
`refs/heads/main` and `refs/tags/v*` of the `echo-pong` repo. Nothing in dev has
push rights.

`image_tag_mutability = "IMMUTABLE"` on **both** repositories — including
quarantine, so a scanned tag cannot be swapped before promotion.

Retention is blanket and time/count-based (30 `v*` releases, 10 `sha-*`
candidates, untagged expire at 14 days; quarantine expires everything at 14
days). **An ECR lifecycle policy has no knowledge of what `echo-pong-gitops`
still references.** It cannot tell a digest pinned in a live Helm values file
from an abandoned one, so the counts are deliberately generous. Any cleanup
beyond them needs a process that diffs candidate digests against the pinned
digests in the GitOps repo first — documented in `docs/future-extensions.md`,
not built.

Quarantine deliberately grants **no** pull to the cluster node roles. If a node
role could pull from quarantine, the promotion gate would be advisory rather
than enforced.

### An honest note on ECR repository policies

Within a single AWS account, ECR authorises a request if **either** the caller's
identity policy **or** the repository policy allows it — a union, not an
intersection. The Allow-only repository policies in `modules/ecr` therefore do
not stop an in-account principal that already has `ecr:*`. They are the binding
control for any future cross-account access, and they document intent at the
resource. The control that actually bounds in-account access is the identity
policy in `modules/iam-github-oidc`, where the release role is scoped to exactly
the two repository ARNs.

---

## 10. Known operational sharp edges

- **`kubernetes_version` validation is a snapshot.** `modules/eks` allows
  `1.31`, `1.32`, `1.33`. EKS support windows move roughly quarterly and AWS
  force-upgrades clusters that fall out of extended support. Re-check the list
  against the AWS docs before every apply. The validation exists to stop a typo,
  not to assert that these versions are still supported.
- **The app sleeps 10 s before its listener opens and has no SIGTERM
  handling.** Neither is fixable from this stack. What the edge does is set
  `connection_attempts = 3` / `connection_timeout = 10` on the origin so a
  connection-level failure is retried rather than surfaced as a 502, and the
  Ingress annotations output sets a generous health-check interval and a
  30-second deregistration delay.
- **Rotating the app token breaks auth until every pod restarts.** The app loads
  its secret once at startup with no reload path, which is why
  `modules/secrets-metadata` deliberately has no `aws_secretsmanager_secret_rotation`.
- **Rotating the origin-verify value is a two-resource change** that must land in
  one apply — CloudFront's custom header and the WAF byte-match rule both read
  the same `random_password`, so they cannot drift, but a partial apply between
  them is a total outage.
- **The system node group's `desired_size` is in `ignore_changes`.** Terraform
  re-asserting it on every apply causes pointless node churn.
- **EBS root volumes use the AWS-managed EBS key, not a CMK.** A CMK requires
  the EC2 Auto Scaling service-linked role to hold a grant on it, which creates
  a dependency cycle between the `kms` and `eks` modules. The data at risk is a
  stateless node's root volume; the volume is still encrypted.
