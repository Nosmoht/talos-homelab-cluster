package conftest.k8s

import rego.v1

# Namespaces where strict workload checks are relaxed for system components.
allowed_system_namespaces := {"kube-system"}

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet"}

podspec(obj) := spec if {
  obj.kind == "Deployment"
  spec := obj.spec.template.spec
}

podspec(obj) := spec if {
  obj.kind == "StatefulSet"
  spec := obj.spec.template.spec
}

podspec(obj) := spec if {
  obj.kind == "DaemonSet"
  spec := obj.spec.template.spec
}

containers(spec) := all_containers if {
  all_containers := array.concat(object.get(spec, "containers", []), object.get(spec, "initContainers", []))
}

is_system_namespace(obj) if {
  ns := object.get(object.get(obj, "metadata", {}), "namespace", "default")
  allowed_system_namespaces[ns]
}

deny contains msg if {
  workload_kinds[input.kind]
  not is_system_namespace(input)
  spec := podspec(input)
  object.get(spec, "hostNetwork", false)
  name := object.get(object.get(input, "metadata", {}), "name", "unknown")
  msg := sprintf("%s/%s enables hostNetwork", [input.kind, name])
}

deny contains msg if {
  workload_kinds[input.kind]
  not is_system_namespace(input)
  spec := podspec(input)
  c := containers(spec)[_]
  sc := object.get(c, "securityContext", {})
  object.get(sc, "privileged", false)
  name := object.get(object.get(input, "metadata", {}), "name", "unknown")
  cname := object.get(c, "name", "unknown")
  msg := sprintf("%s/%s container %s is privileged", [input.kind, name, cname])
}

deny contains msg if {
  workload_kinds[input.kind]
  not is_system_namespace(input)
  spec := podspec(input)
  c := containers(spec)[_]
  resources := object.get(c, "resources", null)
  resources == null
  name := object.get(object.get(input, "metadata", {}), "name", "unknown")
  cname := object.get(c, "name", "unknown")
  msg := sprintf("%s/%s container %s is missing resources", [input.kind, name, cname])
}

deny contains msg if {
  workload_kinds[input.kind]
  not is_system_namespace(input)
  spec := podspec(input)
  c := containers(spec)[_]
  resources := object.get(c, "resources", {})
  not object.get(resources, "requests", null)
  name := object.get(object.get(input, "metadata", {}), "name", "unknown")
  cname := object.get(c, "name", "unknown")
  msg := sprintf("%s/%s container %s is missing resources.requests", [input.kind, name, cname])
}

deny contains msg if {
  workload_kinds[input.kind]
  not is_system_namespace(input)
  spec := podspec(input)
  c := containers(spec)[_]
  resources := object.get(c, "resources", {})
  not object.get(resources, "limits", null)
  name := object.get(object.get(input, "metadata", {}), "name", "unknown")
  cname := object.get(c, "name", "unknown")
  msg := sprintf("%s/%s container %s is missing resources.limits", [input.kind, name, cname])
}
