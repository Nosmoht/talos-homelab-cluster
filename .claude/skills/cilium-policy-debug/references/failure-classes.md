# Cilium Policy Failure Classes

Use this reference to classify observed traffic drops. Match Hubble/cilium-dbg evidence against these classes before proposing fixes.

## 1. Wrong Entity Identity

**Symptom:** Gateway API traffic dropped; Hubble shows source identity `world` but policy expects `ingress`.
**Diagnosis:** `hubble observe --verdict DROPPED --to-namespace <ns> --last 50` — check source identity field.
**Fix:** Use `fromEntities: [world]` or match the actual Cilium-assigned identity for the envoy proxy.

## 2. Wrong API-Server Egress Port

**Symptom:** Pods cannot reach the Kubernetes API. Policy allows port `443` but traffic goes to post-DNAT port `6443`.
**Diagnosis:** `hubble observe --verdict DROPPED --to-port 6443 --last 50`
**Fix:** Add port `6443` to the egress rule targeting the `kube-apiserver` entity, or use `toEntities: [kube-apiserver]` which matches regardless of port.

## 3. Hook/Job Labels Not Covered

**Symptom:** Helm hooks or Jobs fail to start; their labels don't match the endpointSelector in the namespace's CNP.
**Diagnosis:** Compare `kubectl get pods -l <hook-labels> -o wide` labels against CNP `endpointSelector.matchLabels`.
**Fix:** Broaden the endpointSelector to include hook/job label variants, or add a dedicated rule for transient workloads.

## 4. K8s NetworkPolicy + CiliumNetworkPolicy AND Semantics

**Symptom:** Traffic allowed by CNP is still dropped. Both K8s NetworkPolicy and CNP exist in the namespace.
**Diagnosis:** `kubectl get networkpolicy,cnp -n <ns>` — if both exist, Cilium enforces the intersection (AND).
**Fix:** Remove the K8s NetworkPolicy or ensure both policies allow the same flows. Do not mix policy types in the same namespace.

## 5. Missing endpointSelector on Egress

**Symptom:** Egress traffic from specific pods is dropped but the CNP egress section looks correct.
**Diagnosis:** Check if `endpointSelector` at the top level is `{}` (all pods) or matches the source pod labels.
**Fix:** Ensure the top-level `endpointSelector` matches the pods that need the egress rule.

## 6. Gateway API Envoy Identity Mismatch

**Symptom:** Traffic from `cilium-gateway-*` envoy pods is dropped by CNP in the target namespace.
**Diagnosis:** `hubble observe --verdict DROPPED --from-pod kube-system/cilium-gateway-<name> --last 50`
**Fix:** Add an ingress rule matching the envoy pod labels (`app.kubernetes.io/name: envoy`, `io.cilium.gateway/owning-gateway: <name>`) or use `fromEntities: [cluster]` if appropriate.
