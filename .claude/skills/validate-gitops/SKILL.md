---
name: validate-gitops
description: "Run the full GitOps validation pipeline: kustomize render, conftest OPA, kubeconform schema, Kyverno dry-run, and trivy scan. Interprets failures with file-level detail."
argument-hint: "[--overlay <overlay>] [--skip-trivy]"
disable-model-invocation: true
allowed-tools: Bash, Read, Grep
---

# Validate GitOps

## Environment Setup

Read `cluster.yaml` for the overlay name and kubeconfig path.
If the file is missing, use `homelab` as the overlay name.

Extract before running any commands:
```bash
OVERLAY=$(yq '.cluster.overlay // "homelab"' cluster.yaml)
KUBECONFIG=$(yq '.kubeconfig' cluster.yaml)
```

## Reference Files

Read before acting:
- `.claude/rules/manifest-quality.md` — validation commands, SOPS plugin flag, required label policy
- `Makefile` — `validate-gitops` and `validate-kyverno-policies` targets
- `.github/workflows/gitops-validate.yml` — CI pipeline steps (this skill mirrors them)

## Inputs

- `--overlay <name>`: Kustomize overlay to validate. Default: `homelab`.
- `--skip-trivy`: Skip the trivy security scan (saves ~15s, useful for fast iteration).

## Scope Guard

This skill runs the full 7-step pipeline verbosely, with interpreted output.
The pre-commit hook (`.claude/hooks/validate-gitops.sh`) runs only steps 1 and 6 silently.

If a specific Cilium CNP is causing traffic drops (not a manifest schema error):
- Suggest `/cilium-policy-debug` instead.

If ArgoCD is showing a sync failure for a specific app:
- Suggest `/gitops-health-triage` instead.

## Workflow

### 1. Kustomize render

Run:
```bash
kubectl kustomize kubernetes/overlays/<overlay>
```

If SOPS-encrypted secrets are present:
```bash
kubectl kustomize --enable-alpha-plugins kubernetes/overlays/<overlay>
```

If non-zero exit, stop and report:
> "Kustomize render failed. Most common cause: missing resource reference or malformed patch."
Read the error output and identify the specific file and line causing the failure.

### 2. SOPS file verification

Run:
```bash
./scripts/verify_sops_files.sh
```

If non-zero exit, stop and report:
> "SOPS verification failed. A secret may have been committed without encryption. Check for unencrypted *.sops.yaml files."

### 3. Dry-run apply

Run:
```bash
KUBECONFIG=$KUBECONFIG kubectl apply -k kubernetes/overlays/$OVERLAY --dry-run=client
```

This catches resource kind/version mismatches that kustomize render passes through. If non-zero, report the specific resource and API version conflict.

### 4. Kyverno policy validation (if Kyverno policy files changed)

Run:
```bash
make validate-kyverno-policies
```

Only required if `kubernetes/base/infrastructure/platform-network-interface/` files were modified. If non-zero, report which ClusterPolicy has a JMESPath or variable error.

### 5. Conftest OPA policy checks

Run:
```bash
./scripts/run_conftest.sh
```

This reads rendered output from step 1. Failures indicate OPA policy violations (label requirements, resource limits, etc.).

### 6. Kubeconform schema validation

Run:
```bash
kubectl kustomize kubernetes/overlays/<overlay> | kubeconform -strict -ignore-missing-schemas
```

`-ignore-missing-schemas` is intentional — CRD schemas are not in the default registry. If non-zero, report the specific resource failing schema validation.

### 7. Trivy security scan (skip if --skip-trivy)

Run:
```bash
trivy config --severity HIGH,CRITICAL --exit-code 1 \
  --skip-files kubernetes/bootstrap/cilium/cilium.yaml \
  --skip-files kubernetes/overlays/homelab/infrastructure/piraeus-operator/resources/storage-pool-autovg.yaml \
  kubernetes/
```

The two `--skip-files` cover vendor files with known false positives. If non-zero, report the specific resource and the security finding.

## Output

Present a pass/fail summary table:

```
| Step | Check             | Status | Details |
|------|-------------------|--------|---------|
| 1    | Kustomize render  | PASS   | —       |
| 2    | SOPS verify       | PASS   | —       |
| 3    | Dry-run apply     | PASS   | —       |
| 4    | Kyverno policies  | PASS   | —       |
| 5    | Conftest OPA      | PASS   | —       |
| 6    | Kubeconform       | PASS   | —       |
| 7    | Trivy scan        | PASS   | —       |
```

For each failure, provide:
- The specific file path and line number
- What the failure means in plain language
- The suggested fix

## Hard Rules

- Read-only validation. Never modify files to fix failures — report them.
- The hook, this skill, and CI must test the same things. If validation logic changes, update all three: `.claude/hooks/validate-gitops.sh`, this skill, and `.github/workflows/gitops-validate.yml`.
