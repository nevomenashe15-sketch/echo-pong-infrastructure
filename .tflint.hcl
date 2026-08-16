# tflint configuration.
# The AWS ruleset plugin is intentionally NOT enabled here: it requires a
# network fetch of the plugin binary at `tflint --init` time, which makes CI
# dependent on GitHub availability. The bundled terraform ruleset below covers
# the language-level checks (unused declarations, naming, deprecated syntax,
# missing versions) and checkov/trivy cover the AWS security surface.
config {
  call_module_type = "all"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
