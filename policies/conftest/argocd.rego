package conftest.argocd

import rego.v1

# Pragmatic allowlists for known exceptions.
namespace_optional_apps := {}
retry_exempt_apps := {"root"}
kube_system_allowed_projects := {"infrastructure"}
allow_helm_non_exact_revisions := {}
warn_git_unpinned_exempt_apps := {}
enable_git_main_warnings := false

is_application(obj) if {
  api := object.get(obj, "apiVersion", "")
  kind := object.get(obj, "kind", "")
  startswith(api, "argoproj.io/")
  kind == "Application"
}

app_name(obj) := name if {
  name := object.get(object.get(obj, "metadata", {}), "name", "unknown")
}

all_sources(obj) := srcs if {
  spec := object.get(obj, "spec", {})
  multi := object.get(spec, "sources", [])
  single := object.get(spec, "source", null)
  single == null
  srcs := multi
}

all_sources(obj) := srcs if {
  spec := object.get(obj, "spec", {})
  multi := object.get(spec, "sources", [])
  single := object.get(spec, "source", null)
  single != null
  srcs := array.concat([single], multi)
}

is_empty_string(v) if {
  v == ""
}

is_helm_source(src) if {
  object.get(src, "chart", "") != ""
}

is_git_source(src) if {
  object.get(src, "repoURL", "") != ""
  object.get(src, "chart", "") == ""
}

is_exact_version(v) if {
  regex.match("^v?[0-9]+\\.[0-9]+\\.[0-9]+([-.+][0-9A-Za-z.-]+)?$", v)
}

is_floating_revision(v) if {
  lower(v) == "latest"
}

is_floating_revision(v) if {
  v == "*"
}

is_floating_git_ref(v) if {
  lower(v) == "head"
}

is_mainline_git_ref(v) if {
  lower(v) == "main"
}

is_mainline_git_ref(v) if {
  lower(v) == "master"
}

deny contains msg if {
  is_application(input)
  spec := object.get(input, "spec", {})
  project := object.get(spec, "project", "")
  is_empty_string(project)
  msg := sprintf("Application %s must set spec.project", [app_name(input)])
}

deny contains msg if {
  is_application(input)
  name := app_name(input)
  not namespace_optional_apps[name]
  spec := object.get(input, "spec", {})
  ns := object.get(object.get(spec, "destination", {}), "namespace", "")
  is_empty_string(ns)
  msg := sprintf("Application %s must set spec.destination.namespace", [name])
}

deny contains msg if {
  is_application(input)
  spec := object.get(input, "spec", {})
  dest := object.get(spec, "destination", {})
  server := object.get(dest, "server", "")
  cname := object.get(dest, "name", "")
  is_empty_string(server)
  is_empty_string(cname)
  msg := sprintf("Application %s must set spec.destination.server or spec.destination.name", [app_name(input)])
}

deny contains msg if {
  is_application(input)
  src := all_sources(input)[_]
  is_helm_source(src)
  repo := object.get(src, "repoURL", "")
  is_empty_string(repo)
  msg := sprintf("Application %s helm source must set repoURL", [app_name(input)])
}

deny contains msg if {
  is_application(input)
  src := all_sources(input)[_]
  is_helm_source(src)
  chart := object.get(src, "chart", "")
  is_empty_string(chart)
  msg := sprintf("Application %s helm source must set chart", [app_name(input)])
}

deny contains msg if {
  is_application(input)
  src := all_sources(input)[_]
  is_helm_source(src)
  rev := object.get(src, "targetRevision", "")
  is_empty_string(rev)
  msg := sprintf("Application %s helm source must set targetRevision", [app_name(input)])
}

deny contains msg if {
  is_application(input)
  src := all_sources(input)[_]
  is_helm_source(src)
  rev := object.get(src, "targetRevision", "")
  is_floating_revision(rev)
  msg := sprintf("Application %s helm targetRevision %q is floating", [app_name(input), rev])
}

deny contains msg if {
  is_application(input)
  src := all_sources(input)[_]
  is_helm_source(src)
  rev := object.get(src, "targetRevision", "")
  not is_empty_string(rev)
  not is_exact_version(rev)
  app := app_name(input)
  not allow_helm_non_exact_revisions[app]
  msg := sprintf("Application %s helm targetRevision %q must be an exact version", [app, rev])
}

deny contains msg if {
  is_application(input)
  src := all_sources(input)[_]
  is_git_source(src)
  rev := object.get(src, "targetRevision", "")
  is_floating_git_ref(rev)
  msg := sprintf("Application %s git targetRevision %q is not allowed", [app_name(input), rev])
}

warn contains msg if {
  enable_git_main_warnings
  is_application(input)
  spec := object.get(input, "spec", {})
  object.get(spec, "project", "") == "infrastructure"
  src := all_sources(input)[_]
  is_git_source(src)
  rev := object.get(src, "targetRevision", "")
  is_mainline_git_ref(rev)
  app := app_name(input)
  not warn_git_unpinned_exempt_apps[app]
  msg := sprintf("Application %s uses git targetRevision %q in infrastructure; pin tag or commit SHA for production", [app, rev])
}

deny contains msg if {
  is_application(input)
  spec := object.get(input, "spec", {})
  sp := object.get(spec, "syncPolicy", {})
  auto := object.get(sp, "automated", null)
  auto != null
  app := app_name(input)
  not retry_exempt_apps[app]
  retry := object.get(sp, "retry", {})
  limit := object.get(retry, "limit", null)
  limit == null
  msg := sprintf("Application %s has automated sync enabled and must set syncPolicy.retry.limit", [app])
}

deny contains msg if {
  is_application(input)
  spec := object.get(input, "spec", {})
  ns := object.get(object.get(spec, "destination", {}), "namespace", "")
  ns == "kube-system"
  project := object.get(spec, "project", "")
  not kube_system_allowed_projects[project]
  msg := sprintf("Application %s cannot target kube-system outside allowed projects", [app_name(input)])
}
