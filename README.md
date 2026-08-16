# echo-pong-infrastructure

Terraform for the AWS estate behind **echo-pong** — a small Go HTTP service
(`GET /ping`, `GET /pong` behind an `Authorization` header; public `GET /health`
and `GET /`).

This is one of four repositories. **Read the ownership boundaries below before
changing anything** — most of the design decisions here exist to keep exactly
one system in charge of each resource.

| Repository | Owns |
|---|---|
| `echo-pong` | The Go app and its container image. |
| **`echo-pong-infrastructure`** (this repo) | AWS: VPC, EKS, ECR, IAM, KMS, Route 53/ACM, CloudFront, WAF, Secrets Manager metadata, and the Argo CD install. |
| `echo-pong-gitops` | Every Kubernetes object except the Argo CD install: platform add-ons, Karpenter NodePool/EC2NodeClass, the app's Helm release and Ingress. |
| `echo-pong-workflows` | Reusable GitHub Actions workflows. Assumes the IAM roles this repo creates. |

---

## The ownership boundaries that matter

### 1. Terraform does not create the app's ALB

> **Terraform never declares an `aws_lb`, `aws_lb_listener`, `aws_lb_target_group`, or `Ingress` for the app.**

The AWS Load Balancer Controller creates and owns that ALB, driven by the
Ingress in `echo-pong-gitops`. Terraform contributes only the IAM role the
controller needs (`modules/iam-pod-identity`), the ACM certificate it attaches,
and the regional Web ACL it associates.

If Terraform also declared the ALB, two systems would hold write access to one
resource and would fight over it on every reconcile. This is the single most
important rule in the repository.

**Consequences you will notice:**

- `origin.<domain>` is **not** created by Terraform. That record points at the
  controller's ALB, which does not exist at apply time. `echo-pong-gitops` sets
  `external-dns.alpha.kubernetes.io/hostname` on the Ingress and external-dns
  publishes it.
- Between `terraform apply` and the first successful Argo CD sync, CloudFront
  returns **502**. That is correct and visible, not a bug.

### 2. Terraform touches Kubernetes exactly once

`modules/argocd-bootstrap` installs Argo CD and creates **one** `Application`,
pointing at the app-of-apps root in `echo-pong-gitops`. After that, Terraform
never touches a Kubernetes object again.

The exception exists only because Argo CD cannot install Argo CD.

### 3. Terraform never holds the app's secret value

`modules/secrets-metadata` creates the Secrets Manager **container** — name,
KMS key, tags. It never sets `secret_string`. The value is set once, out of
band, by a human. External Secrets Operator reads it; the app pod holds no AWS
identity at all.

### 4. Karpenter: IAM here, policy in GitOps

This repo creates the Karpenter controller role, the node role, and the
instance profile. The `NodePool` and `EC2NodeClass` — what may actually be
launched — live in `echo-pong-gitops`. IAM changes rarely; capacity policy
changes weekly.

---

## Layout

```
bootstrap/            State backend. Separate state, applied once, by hand.
envs/dev/             Root module. State key dev/terraform.tfstate.
envs/prod/            Root module. State key prod/terraform.tfstate.
                      Also owns the account-global singletons (see below).
modules/              All resource definitions. No third-party registry modules.
docs/                 architecture.md, future-extensions.md, cost-estimate.md
```

Three root modules, three independent states. `modules/` is never applied
directly.

### Account-global singletons

A single AWS account hosts both environments, and some resources have literal,
environment-agnostic names:

- the GitHub Actions OIDC provider (one per issuer URL per account),
- the five `echo-pong-gh-*` roles,
- the `echo-pong` and `echo-pong-quarantine` ECR repositories.

Exactly one root module may create these, or the second apply fails with
`EntityAlreadyExists`. **`envs/prod` owns them**, gated on
`var.manage_account_globals`.

**Apply order is therefore: `bootstrap/` → `envs/prod/` → `envs/dev/`.**

---

## Bootstrap ordering (the chicken-and-egg problem)

Three circular dependencies have to be broken by hand, once:

1. **State backend.** Every root module stores state in an S3 bucket, but that
   bucket is itself Terraform-managed. `bootstrap/` therefore has **no backend
   block** — it runs with local state.

2. **OIDC provider.** The GitHub Actions roles are only assumable once the OIDC
   provider exists, but the provider is created by a Terraform run that would
   need to assume one of those roles.

3. **State bucket policy.** The bucket policy allow-lists the role ARNs, but
   those roles are created later, in `envs/prod`.

### The sequence

```bash
# 1. Bootstrap, with a human's credentials. Local state.
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # leave the principal lists EMPTY
terraform init && terraform apply
terraform output backend_config_snippet

# 2. Prod. Creates the OIDC provider, the five roles, and ECR.
cd ../envs/prod
cat > backend.hcl <<EOF
bucket         = "<state_bucket_name from step 1>"
region         = "<region>"
dynamodb_table = "<lock_table_name from step 1>"
kms_key_id     = "<state_kms_key_arn from step 1>"
encrypt        = true
EOF
cp terraform.tfvars.example terraform.tfvars   # fill in the state_* ARNs from step 1
terraform init -backend-config=backend.hcl

#    First apply of a NEW cluster: Argo CD off. See "First apply" below.
terraform apply -var enable_argocd=false
terraform apply                                 # again, with Argo CD on

# 3. Tighten the state bucket policy now that the roles exist.
cd ../../bootstrap
#    Fill state_reader_principal_arns / state_writer_principal_arns
terraform apply

# 4. Dev.
cd ../envs/dev
terraform init -backend-config=backend.hcl      # same file, key differs per env
terraform apply -var enable_argocd=false
terraform apply
```

After this, `echo-pong-gh-bootstrap` exists to redo step 1 or 3 non-interactively.
It is the only role that may create an OIDC provider, and it is gated on the
`bootstrap` GitHub Environment. It should be used approximately never.

### First apply

`enable_argocd = false` on the first apply of a new cluster is **not optional**.
The `helm` provider authenticates against a cluster endpoint that does not exist
until `module.eks` has been created, so a plan that includes `helm_release`
fails before it can create the thing it needs. Two applies; thereafter one.

### Setting the secret value

Once, from a trusted machine, never from CI:

```bash
aws secretsmanager put-secret-value \
  --secret-id echo-pong/prod/api-token \
  --region <region> \
  --secret-string '<TOKEN>'
```

Never put this value in a `.tf` file, a `.tfvars` file, or a CI variable that a
`terraform plan` could echo.

---

## ECR: one registry, not one per environment

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

### Lifecycle policies cannot know what is deployed

Retention here is **blanket and time/count-based**:

| Repository | Rule |
|---|---|
| `echo-pong` | Keep last 30 `v*` releases; last 10 `sha-*` candidates; untagged expire at 14 days. |
| `echo-pong-quarantine` | Everything expires at 14 days, tagged or not. |

**An ECR lifecycle policy has no knowledge of what `echo-pong-gitops` still
references.** It cannot tell a digest that is pinned in a live Helm values file
from an abandoned one, so an aggressive rule will eventually delete an image
that a running cluster or a rollback needs.

The retention counts above are deliberately generous for that reason. Any
cleanup beyond them must be done by a separate process that diffs candidate
digests against the pinned digests in `echo-pong-gitops` before deleting.
**That process is documented, not built** — see `docs/future-extensions.md`.

---

## CI lives in the sibling repo

`.github/workflows/` in this repository is intentionally near-empty. Workflow
ownership belongs to `echo-pong-workflows`; this repo only provides the IAM
roles those workflows assume:

| Role | Trusted for | Can do |
|---|---|---|
| `echo-pong-gh-ci-validation` | all four repos, any ref | read-only |
| `echo-pong-gh-ecr-release` | `echo-pong`, `main` + `v*` tags | ECR push/promote on two repos |
| `echo-pong-gh-tf-plan` | `echo-pong-infrastructure`, any ref | read-only + state read/lock |
| `echo-pong-gh-tf-apply` | `echo-pong-infrastructure`, `main` **and** `environment:production-infra` | mutate this stack |
| `echo-pong-gh-bootstrap` | `echo-pong-infrastructure`, `environment:bootstrap` | OIDC provider + state backend only |

No role has `AdministratorAccess`. No trust policy uses a wildcard repository.

---

## Lock files

`.terraform.lock.hcl` **is committed** in `bootstrap/`, `envs/dev/` and
`envs/prod/`. `.tfvars` files are not (only `.tfvars.example`).

## Validation

```bash
terraform fmt -recursive -check
tflint --recursive
checkov -d . --skip-path '.terraform'
trivy config --skip-dirs '**/.terraform' .
gitleaks detect --no-git -s .

for d in bootstrap envs/dev envs/prod; do
  (cd $d && terraform init -backend=false && terraform validate)
done
```

Scanner findings that are deliberate are recorded with justifications in
`.checkov.yml` and `.trivyignore` — read those before "fixing" a finding.

## Further reading

- [`docs/architecture.md`](docs/architecture.md) — request flow, every design decision and its reasoning.
- [`docs/future-extensions.md`](docs/future-extensions.md) — what was deliberately not built.
- [`docs/cost-estimate.md`](docs/cost-estimate.md) — rough monthly cost, dev vs prod.
