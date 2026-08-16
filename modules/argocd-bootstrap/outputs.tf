output "argocd_namespace" {
  description = "Namespace Argo CD runs in."
  value       = var.argocd_namespace
}

output "argocd_chart_version" {
  description = "Pinned argo-cd chart version that was installed."
  value       = var.argocd_chart_version
}

output "bootstrap_application_name" {
  description = "Name of the single root Application, or empty if not created."
  value       = var.create_bootstrap_application ? "${var.name_prefix}-root" : ""
}

output "argocd_access_command" {
  description = "How to reach the Argo CD UI. There is no Ingress by design."
  value       = "kubectl -n ${var.argocd_namespace} port-forward svc/argocd-server 8080:80"
}

output "argocd_initial_password_command" {
  description = "How to read the initial admin password. Rotate and delete this Secret after first login -- it is a Kubernetes object, so Terraform neither creates nor manages it."
  value       = "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
