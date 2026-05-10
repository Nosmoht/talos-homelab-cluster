# ArgoCD Remediation Patterns

## Failure Class Remediation Table

| Failure Class | Git Change | Emergency Live Action |
|---|---|---|
| Webhook/defaulted-field drift | Add `ignoreDifferences` for the specific defaulted fields in the Application CR, OR add explicit defaulted values to the manifest | None needed |
| Immutable field/selector rejection | Add `Replace: true` sync option to the Application CR, or delete and recreate the resource in git | `kubectl delete <resource>` then trigger sync |
| Missing CRD/order dependency | Add `argocd.argoproj.io/sync-wave` annotations: CRDs at wave `-1`, consumers at wave `0+` | None needed |
| Cilium policy blocking traffic | Update CiliumNetworkPolicy in overlay to allow the required flow | None needed |
| Stale operation state / exhausted retries | `kubectl -n argocd patch application <app> --type json -p '[{"op":"remove","path":"/status/operationState"}]'` then git no-op commit to trigger resync | Must follow with git sync |
| Admission webhook rejection | Fix or disable the rejecting webhook; update manifest to pass validation | `kubectl delete validatingwebhookconfiguration <name>` if safe |
| Pre/post-sync hook failure | Fix the failing Job/hook manifest in git; check resource limits and image availability | Check hook pod logs: `kubectl -n <ns> logs -l app.kubernetes.io/managed-by=argocd --tail=50` |

## Confidence Calibration

- **High:** Failure message directly names the resource and field causing the issue. One failure class clearly matches.
- **Medium:** Error pattern matches circumstantially (string similarity) but no confirmed `argocd app diff` output yet.
- **Low:** Multiple failure classes are plausible. Diff not yet obtained. Further investigation required.

## Controller Log Inspection

When `operationState.message` is empty or generic ("ComparisonError"), inspect controller and repo-server logs:

```bash
KUBECONFIG=<kubeconfig> kubectl -n argocd logs deployment/argocd-application-controller --tail=50 | grep <app>
KUBECONFIG=<kubeconfig> kubectl -n argocd logs deployment/argocd-repo-server --tail=50
```
