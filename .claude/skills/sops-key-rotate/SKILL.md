---
name: sops-key-rotate
description: Rotate the AGE encryption key for all SOPS-encrypted secrets in the repo. Covers key generation, re-encryption, and ArgoCD secret update.
argument-hint: "[--add-only]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
---

# SOPS Key Rotation

## Environment Setup

Read `cluster.yaml` to load cluster-specific values.

This skill rotates the AGE key used to encrypt all `*.sops.yaml` secrets in the repo.
The current key recipients are defined in `.sops.yaml` at the repo root.

**Two-phase rotation approach (safe, no outage):**
1. **Phase 1 (Add):** Add the new key as a recipient alongside the old key. Re-encrypt all files — both keys can decrypt.
2. **Phase 2 (Remove):** Remove the old key, re-encrypt to strip old key access. Update the Kubernetes secret that holds the private key.

`--add-only` flag: run only Phase 1 (useful when distributing the new key to multiple operators first).

## Reference Files

Read before proceeding:
- `.sops.yaml` — current recipients and path regexes
- `scripts/verify_sops_files.sh` — verification script run by pre-commit hook

## Pre-Checks

### 1. Verify current SOPS state

Confirm all files are currently encrypted (pre-commit hook also enforces this):
```bash
bash scripts/verify_sops_files.sh
```

If any file fails, stop. Fix encryption state before proceeding.

### 2. Inventory files to re-encrypt

```bash
git ls-files | grep '\.sops\.yaml$'
```

Record this list. Every file in this output must be re-encrypted in both phases.

### 3. Verify `age` and `sops` tooling

```bash
command -v age-keygen >/dev/null 2>&1 || { echo "install age (https://github.com/FiloSottile/age)"; exit 1; }
sops --version
```

If either is missing, stop and report: "Install `age` and `sops` before proceeding."

---

## Phase 1 — Add New Key

### 1.1 Generate new AGE keypair

```bash
install -m 600 /dev/null /tmp/new-age-key.txt
age-keygen -o /tmp/new-age-key.txt
# Output format:
# # created: <timestamp>
# # public key: age1<pubkey>
# AGE-SECRET-KEY-1<privkey>
```

Extract public key:
```bash
grep '^# public key:' /tmp/new-age-key.txt | awk '{print $NF}'
# → age1<newpubkey>
```

**IMPORTANT:** The private key in `/tmp/new-age-key.txt` is the secret. The file is created with
`mode 600` (owner-readable only) — do not change permissions. It must be distributed to operators
and stored in the cluster before Phase 2. Do not delete this file until Phase 2 is complete
and verified.

### 1.2 Read current recipients

```bash
cat .sops.yaml
```

Note the existing AGE public key(s) under each `creation_rules[].age` entry.

### 1.3 Add new key to .sops.yaml recipients

Each `age:` field accepts a comma-separated list. Add the new public key:

Example — before:
```yaml
creation_rules:
  - path_regex: talos/secrets\.yaml$
    age: age1<oldpubkey>
  - path_regex: kubernetes/.*\.sops\.yaml$
    age: age1<oldpubkey>
```

After:
```yaml
creation_rules:
  - path_regex: talos/secrets\.yaml$
    age: age1<oldpubkey>,age1<newpubkey>
  - path_regex: kubernetes/.*\.sops\.yaml$
    age: age1<oldpubkey>,age1<newpubkey>
```

Use the Edit tool to update `.sops.yaml`.

### 1.4 Re-encrypt all files with both keys

For each file in the inventory:
```bash
SOPS_AGE_KEY_FILE=/path/to/current-age-key.txt sops updatekeys --yes <file>
```

The current private key must be accessible for decryption during updatekeys. It is typically stored in
`~/.config/sops/age/keys.txt` or set via `SOPS_AGE_KEY_FILE`.

Run for all files (exports key file so decryption is deterministic):
```bash
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
while IFS= read -r f; do
  echo "Updating keys: $f"
  sops updatekeys --yes "$f"
  echo "  → done"
done < <(git ls-files | grep '\.sops\.yaml$')
```

### 1.5 Verify Phase 1

Both keys can now decrypt:
```bash
# Verify with OLD key (current default):
sops -d talos/secrets.yaml > /dev/null && echo "old key: OK"

# Verify with NEW key:
SOPS_AGE_KEY_FILE=/tmp/new-age-key.txt sops -d talos/secrets.yaml > /dev/null && echo "new key: OK"
```

Run full verification script:
```bash
bash scripts/verify_sops_files.sh
```

If `--add-only` was requested, stop here. Distribute the new private key and wait for confirmation
before Phase 2.

---

## Phase 2 — Remove Old Key

### Phase 2 Pre-Check

Before proceeding, confirm Phase 1 is fully committed, pushed, and reconciled:

```bash
# Phase 1 must be on main:
git log origin/main -1 -- .sops.yaml
# Should show the Phase 1 commit. If HEAD is ahead of origin/main, push first.

# ArgoCD must be healthy (no decryption errors):
KUBECONFIG=<kubeconfig> kubectl get applications -n argocd -o json | \
  jq '.items[] | {name: .metadata.name, health: .status.health.status, sync: .status.sync.status}'
```

If ArgoCD shows any app with `health != Healthy` or sync errors related to SOPS: stop. Fix before removing old key.

**Prerequisite:** Confirm new private key is:
- Available in the local keyring used by sops (or set via `SOPS_AGE_KEY_FILE`)
- Stored in the cluster's ArgoCD SOPS secret (see §Cluster Secret Update below)
- Backed up by all operators who need access

**Confirmation gate:**
```
Phase 2 — Remove Old Key
Action: Remove old AGE key from .sops.yaml and re-encrypt all SOPS files.
After this step, the old private key can no longer decrypt any file.
Old key: age1<oldpubkey>
New key: age1<newpubkey>
Files affected: <N> files
This is IRREVERSIBLE without the old private key.
Proceed? (yes/no)
```

### 2.1 Remove old key from .sops.yaml

Edit `.sops.yaml` to remove the old key from each `age:` entry, leaving only the new key:

```yaml
creation_rules:
  - path_regex: talos/secrets\.yaml$
    age: age1<newpubkey>
  - path_regex: kubernetes/.*\.sops\.yaml$
    age: age1<newpubkey>
```

### 2.2 Re-encrypt all files with new key only

```bash
# Must use NEW key for this step:
SOPS_AGE_KEY_FILE=/tmp/new-age-key.txt \
  bash -c 'while IFS= read -r f; do
    echo "Updating keys: $f"
    sops updatekeys --yes "$f"
  done < <(git ls-files | grep "\.sops\.yaml$")'
```

### 2.3 Verify Phase 2

Old key no longer works, new key works:
```bash
# New key: must succeed
SOPS_AGE_KEY_FILE=/tmp/new-age-key.txt sops -d talos/secrets.yaml > /dev/null && echo "new key: OK"

# Full script:
SOPS_AGE_KEY_FILE=/tmp/new-age-key.txt bash scripts/verify_sops_files.sh
```

### 2.4 Update cluster ArgoCD SOPS secret

The cluster has a Kubernetes Secret named **`sops-age-key`** in the `argocd` namespace holding the
AGE private key used by ArgoCD's SOPS decryption. This name is authoritative — confirmed in
`Makefile` (target `argocd-install`) and `kubernetes/base/infrastructure/argocd/values.yaml`
(volume mount `sops-age`).

Update it to the new private key (kubectl CLI required — MCP server is read-only):

```bash
# Use --from-file to preserve the multi-line key file faithfully:
KUBECONFIG=<kubeconfig> kubectl create secret generic sops-age-key \
  -n argocd \
  --from-file=keys.txt=/tmp/new-age-key.txt \
  --dry-run=client -o yaml | \
  KUBECONFIG=<kubeconfig> kubectl apply -f -
```

After update, restart ArgoCD repo-server to pick up the new key:
```bash
KUBECONFIG=<kubeconfig> kubectl rollout restart deployment argocd-repo-server -n argocd
KUBECONFIG=<kubeconfig> kubectl rollout status deployment argocd-repo-server -n argocd --timeout=120s
```

### 2.5 Verify ArgoCD can still decrypt

Force ArgoCD to re-sync an app that uses a SOPS secret:
```bash
KUBECONFIG=<kubeconfig> kubectl annotate application root -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

Check no apps show `ComparisonError` with SOPS/decryption failures:
```bash
KUBECONFIG=<kubeconfig> kubectl get applications -n argocd -o json | \
  jq '.items[] | select(.status.conditions[]?.message | test("sops|decrypt|age"; "i")) | .metadata.name'
```

---

## Commit

After Phase 1 or Phase 2 (never intermediate state):

```bash
git add .sops.yaml
git add $(git ls-files | grep '\.sops\.yaml$')
```

Verify no plaintext secrets in diff:
```bash
git diff --cached | grep -v '^---\|^+++\|^@@' | grep -v 'sops:\|ENC\[' | head -20
# Should show only .sops.yaml metadata changes and ENC[] ciphertext blocks
```

Commit:
```bash
git commit -m "chore(sops): rotate AGE encryption key"
# Then push and let ArgoCD reconcile
git push
```

## Post-Rotation Checklist

- [ ] `SOPS_AGE_KEY_FILE=/tmp/new-age-key.txt bash scripts/verify_sops_files.sh` exits 0
- [ ] `.sops.yaml` contains only new public key
- [ ] ArgoCD repo-server restarted and all apps sync without decryption errors
- [ ] New private key distributed to all operators via out-of-band secure channel
- [ ] New private key stored in password manager / secrets vault
- [ ] `~/.config/sops/age/keys.txt` updated to include new private key (remove old)
- [ ] `/tmp/new-age-key.txt` securely deleted: `shred -u /tmp/new-age-key.txt`
- [ ] Old private key file securely deleted: `shred -u /tmp/old-age-key.txt` (if applicable)

## Hard Rules

- Never commit the AGE private key to git. Private keys live only in `~/.config/sops/age/keys.txt`,
  Kubernetes secrets, and operator vaults.
- Never delete the old private key until Phase 2 verification passes.
- If Phase 1 commit is merged but Phase 2 is not yet done: old key still works — this is the safe
  intermediate state. Do not leave `.sops.yaml` with a mix of old and new recipients for more than
  one working day.
- The pre-commit hook (`scripts/verify_sops_files.sh`) will block commits with plaintext
  `*.sops.yaml` files. If it triggers, do not use `--no-verify`.
