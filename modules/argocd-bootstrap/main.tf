# =============================================================================
# Argo CD bootstrap -- THE ONE PLACE TERRAFORM TOUCHES KUBERNETES
# =============================================================================
#
#   ##########################################################################
#   #  AFTER THIS MODULE, TERRAFORM NEVER TOUCHES A KUBERNETES OBJECT AGAIN. #
#   ##########################################################################
#
# Everything else in the cluster -- the AWS Load Balancer Controller, External
# Secrets Operator, Karpenter, the Karpenter NodePool and EC2NodeClass, the
# echo-pong Helm release, the Ingress that produces the app's ALB -- is
# installed by Argo CD reading echo-pong-gitops. Not by Terraform.
#
# The exception exists because of a genuine ordering problem and nothing else:
# Argo CD cannot install Argo CD. Something outside the GitOps loop has to
# create the first controller, and Terraform is already the thing that created
# the cluster it runs on.
#
# WHY NOT kubernetes_manifest FOR ANY OF THIS:
# The kubernetes_manifest resource performs a server-side dry-run at PLAN time.
# That makes `terraform plan` fail whenever the cluster is unreachable or does
# not yet exist -- including on the very first apply, and on every CI plan run
# from a runner without cluster credentials. Both objects below are therefore
# delivered as Helm releases (the upstream chart, and a tiny local chart for
# the bootstrap Application), which render at APPLY time only.
# =============================================================================

locals {
  # Argo CD's own components must tolerate the system taint: at bootstrap time
  # the system node group is the only capacity in the cluster, and Karpenter
  # is not running yet -- Argo CD is what will install it.
  system_tolerations = [{
    key      = var.system_node_taint_key
    operator = "Equal"
    value    = "true"
    effect   = "NoSchedule"
  }]

  argocd_values = {
    global = {
      tolerations = local.system_tolerations
    }

    configs = {
      params = {
        # No TLS on the argocd-server pod itself. There is deliberately no
        # Ingress for Argo CD (see below), so the only access path is
        # `kubectl port-forward`, which is already an authenticated,
        # encrypted channel through the Kubernetes API.
        "server.insecure" = true
      }

      cm = {
        # Let Argo CD manage resources it did not create, needed for the
        # add-ons it adopts.
        "application.resourceTrackingMethod" = "annotation"
        "timeout.reconciliation"             = "180s"
      }
    }

    # NO INGRESS. An Ingress here would be reconciled into an ALB by the AWS
    # Load Balancer Controller -- which Argo CD has not installed yet at this
    # point in the ordering -- and it would put the cluster's GitOps control
    # plane on the public internet. Access is via:
    #   kubectl -n argocd port-forward svc/argocd-server 8080:80
    server = {
      ingress  = { enabled = false }
      service  = { type = "ClusterIP" }
      replicas = var.high_availability ? 2 : 1
    }

    controller = {
      replicas = var.high_availability ? 2 : 1
    }

    repoServer = {
      replicas = var.high_availability ? 2 : 1
    }

    applicationSet = {
      replicas = var.high_availability ? 2 : 1
    }

    redis-ha = {
      enabled = var.high_availability
    }

    # The bundled non-HA Redis is only used when redis-ha is off.
    redis = {
      enabled = !var.high_availability
    }

    # Argo CD needs no AWS identity: it reads a public Git repository and talks
    # to the Kubernetes API in-cluster. There is deliberately no Pod Identity
    # association for it in modules/iam-pod-identity.
    notifications = { enabled = false }
    dex           = { enabled = false }
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = var.argocd_namespace
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  values = [yamlencode(local.argocd_values)]

  # Wait for the controller to be ready before the bootstrap Application is
  # applied -- otherwise the Application CRD may not exist yet.
  wait          = true
  wait_for_jobs = true
  timeout       = var.helm_timeout_seconds

  # Argo CD ships its CRDs in the chart. Without this, a chart upgrade leaves
  # the CRDs at the old version and Applications fail validation in ways that
  # look like Git problems.
  skip_crds = false

  # If the release is ever removed from Terraform, do NOT let Helm's uninstall
  # cascade. See the deletion discussion on the bootstrap Application below.
  atomic          = false
  cleanup_on_fail = false
}

# -----------------------------------------------------------------------------
# The single bootstrap Application (app-of-apps entrypoint)
# -----------------------------------------------------------------------------
# DECISION: Terraform creates exactly ONE Application, here, and it points at
# the app-of-apps root in echo-pong-gitops. Terraform creates no other
# Kubernetes object, ever.
#
# The alternative considered was leaving even this to a documented
# `kubectl apply -f` run by a human after terraform apply. Rejected: it makes
# the handoff a step in a runbook rather than a resource in a graph, so a
# rebuilt cluster is silently inert until someone remembers the command. One
# Terraform-managed Application means `terraform apply` produces a cluster that
# converges on its own, which is the property that matters.
#
# --- DELETION SEMANTICS, WHICH ARE THE DANGEROUS PART -----------------------
# The root Application deliberately carries NO
#   finalizers: [resources-finalizer.argocd.argoproj.io]
#
# With that finalizer, deleting the Application cascade-deletes every resource
# it manages -- which for an app-of-apps root means every child Application and
# transitively the entire cluster workload set. A `terraform destroy`, or even
# a careless `terraform state rm` followed by an apply, would take the whole
# platform down.
#
# Without the finalizer, deleting the root Application orphans its children:
# the workloads keep running, unmanaged, and can be re-adopted by re-creating
# the Application. That is the correct failure mode for a bootstrap handoff.
# Orphaned-but-running is recoverable in minutes; cascade-deleted is not.
#
# The prune/selfHeal policy below applies to the CHILDREN Argo CD manages, not
# to this object's own deletion.
resource "helm_release" "bootstrap_application" {
  count = var.create_bootstrap_application ? 1 : 0

  name      = "echo-pong-bootstrap"
  namespace = var.argocd_namespace

  # A vendored local chart, not a remote one: this is three lines of YAML and
  # pulling it from a registry would add a network dependency to the most
  # critical handoff in the stack.
  chart = "${path.module}/chart"

  values = [yamlencode({
    namePrefix      = var.name_prefix
    argocdNamespace = var.argocd_namespace
    repoURL         = var.gitops_repo_url
    targetRevision  = var.gitops_target_revision
    path            = var.gitops_root_path
  })]

  wait    = true
  timeout = 300

  depends_on = [helm_release.argocd]
}
