# Kernel Parameter Layer Baselines

Per-layer expected sysctl values consumed by `kernel-param-auditor`. The SKILL parses the **fenced YAML blocks** below at runtime: each `# layerN-baseline-yaml-start` / `# layerN-baseline-yaml-end` marker pair delimits one layer's baseline map keyed by sysctl path.

Three layers, three audit grades:

- **Layer 1 — Universal**: Linux/Kubernetes hard requirements. Drift = workload-affecting bug. Severity CRITICAL on all roles.
- **Layer 2 — Talos KSPP**: vendor security-hardening defaults. Drift = Talos hardening regression OR intentional override that should be documented. Severity WARNING on all roles. Pinned to **Talos v1.12.6** — see §Maintenance.
- **Layer 3 — Cluster Tuning**: this repo's `talos/patches/common.yaml`. Drift = `apply-config` did not converge OR `common.yaml` modified without re-apply. Severity WARNING on all roles. Mechanically enforced by `.github/workflows/sysctl-baseline-check.yml`.

Cluster-side: `talos/patches/common.yaml` enforces 61 sysctls uniformly across `cp/worker/storage/gpu` roles; per-role divergence is not modelled in V1. The SKILL stays role-aware in its output JSON (each result carries `role:`); only the baseline tables are role-collapsed.

## Roles

| Role | Detection rule (in priority order) |
|---|---|
| `cp` | Node has label `node-role.kubernetes.io/control-plane` (value `""` or `"true"`) |
| `storage` | Node has label `feature.node.kubernetes.io/storage-nvme.present=true` AND not `cp` |
| `gpu` | Node name contains `gpu` OR has label `node.kubernetes.io/gpu` AND not `cp`/`storage` |
| `worker` | Default fallback for any node not matching above |

A node may match `cp` and one of `storage`/`gpu` simultaneously. Precedence is `cp > storage > gpu > worker` — control-plane responsibilities dominate.

---

## §Layer 1 — Universal (K8s/Linux requirement)

**Authority**:
- Kubernetes networking docs — https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Cilium installation prerequisites — https://docs.cilium.io/en/stable/operations/system_requirements/
- kernel.org `Documentation/networking/ip-sysctl.rst`
- `.claude/rules/talos-config.md` "Cilium BPF bypasses kernel FIB, causing false-positive martian drops" (rp_filter rationale)

**Severity**: CRITICAL on all roles. Drift = workload-affecting bug (pod networking, NetworkPolicy enforcement, or Cilium BPF datapath breakage).

```yaml
# layer1-baseline-yaml-start
sysctls:
  # K8s pod networking requirement: enables IP forwarding for pod-to-pod and pod-to-external traffic
  net.ipv4.ip_forward: { expected: "1" }

  # NetworkPolicy enforcement: bridge-netfilter must intercept bridged traffic for iptables rules
  net.bridge.bridge-nf-call-iptables: { expected: "1" }
  net.bridge.bridge-nf-call-ip6tables: { expected: "1" }

  # Cilium BPF datapath requirement: kernel rp_filter false-positive-drops pod-to-pod traffic as
  # martian when Cilium BPF bypasses kernel FIB. Cilium handles source validation via BPF.
  # Drift to "1" silently breaks pod networking — HIGHEST priority audit signal.
  net.ipv4.conf.all.rp_filter: { expected: "0" }
  net.ipv4.conf.default.rp_filter: { expected: "0" }
# layer1-baseline-yaml-end
```

---

## §Layer 2 — Talos KSPP (vendor hardening profile)

**Authority** (pinned to Talos v1.12.6):
- Talos v1.12 default hardening + CIS compliance — https://www.talos.dev/v1.12/talos-guides/configuration/cis/
- Kernel Self Protection Project (KSPP) recommendations — https://kspp.github.io/Recommended_Settings
- Live snapshot via `mcp__talos__talos_get KernelParamStatus` on node-03 (control-plane, M910q)

**Severity**: WARNING on all roles. Drift = Talos hardening regression OR intentional override that should be documented in `common.yaml` (which makes it a Layer-3 entry instead).

**Important — overlap with Layer 3**: `kernel.kexec_load_disabled`, `vm.mmap_rnd_bits`, `vm.mmap_rnd_compat_bits` appear in BOTH the Talos KSPP defaults AND `common.yaml`. They are classified here as L2 (vendor hardening source-of-truth). The CI parity workflow will still verify their values match `common.yaml` (no silent override allowed).

```yaml
# layer2-baseline-yaml-start
sysctls:
  # --- KSPP kernel pointer/info disclosure mitigations ---
  kernel.kptr_restrict: { expected: "2" }
  kernel.dmesg_restrict: { expected: "1" }
  kernel.perf_event_paranoid: { expected: "3" }

  # --- KSPP attack surface reduction (kexec/eBPF/namespaces) ---
  kernel.kexec_load_disabled: { expected: "1" }   # also in common.yaml; classified L2
  kernel.unprivileged_bpf_disabled: { expected: "1" }
  user.max_user_namespaces: { expected: "0" }

  # --- KSPP ptrace + JIT hardening ---
  kernel.yama.ptrace_scope: { expected: "2" }
  net.core.bpf_jit_harden: { expected: "2" }

  # --- KSPP filesystem race protections (CVE-2007-2371 family) ---
  fs.protected_fifos: { expected: "2" }
  fs.protected_hardlinks: { expected: "1" }
  fs.protected_regular: { expected: "2" }
  fs.protected_symlinks: { expected: "1" }

  # --- KSPP ASLR entropy ---
  vm.mmap_rnd_bits: { expected: "32" }            # also in common.yaml; classified L2
  vm.mmap_rnd_compat_bits: { expected: "16" }     # also in common.yaml; classified L2
  kernel.randomize_va_space: { expected: "2" }

  # --- KSPP panic policy (auto-reboot on kernel panic so HA reschedules pods) ---
  kernel.panic: { expected: "10" }
  kernel.panic_on_oops: { expected: "1" }
# layer2-baseline-yaml-end
```

---

## §Layer 3 — Cluster Tuning (this repo's `common.yaml`)

**Authority**: `talos/patches/common.yaml` (CI-enforced via `.github/workflows/sysctl-baseline-check.yml`).

**Severity**: WARNING on all roles. Drift = `talosctl apply-config` did not converge to the live node, OR `common.yaml` was modified without re-apply. Either way, the live kernel state diverges from the declared cluster intent.

`advisory: true` entries are **aspirational** — declared in this baseline as desirable hygiene but **not** in `common.yaml`. The SKILL emits these as INFO findings (no verdict effect); the CI workflow accepts them as a one-way diff (baseline-only, no `common.yaml` enforcer required).

```yaml
# layer3-baseline-yaml-start
sysctls:
  # --- Storage I/O dirty-page tuning (SSD/NVMe) ---
  vm.dirty_ratio: { expected: "10" }
  vm.dirty_background_ratio: { expected: "5" }
  vm.dirty_expire_centisecs: { expected: "1500" }
  vm.dirty_writeback_centisecs: { expected: "300" }

  # --- Memory management ---
  vm.overcommit_memory: { expected: "1" }
  vm.panic_on_oom: { expected: "0" }
  vm.max_map_count: { expected: "524288" }
  vm.min_free_kbytes: { expected: "65536" }

  # --- TCP buffers (DRBD replication needs deep buffers) ---
  net.core.rmem_max: { expected: "16777216" }
  net.core.wmem_max: { expected: "16777216" }
  net.core.rmem_default: { expected: "1048576" }
  net.core.wmem_default: { expected: "1048576" }
  net.ipv4.tcp_rmem: { expected: "4096 1048576 16777216" }
  net.ipv4.tcp_wmem: { expected: "4096 1048576 16777216" }
  net.core.optmem_max: { expected: "2097152" }

  # --- TCP behaviour ---
  net.ipv4.tcp_slow_start_after_idle: { expected: "0" }
  net.ipv4.tcp_tw_reuse: { expected: "1" }
  net.ipv4.ip_local_port_range: { expected: "1024 65535" }
  net.ipv4.tcp_fastopen: { expected: "3" }
  net.ipv4.tcp_mtu_probing: { expected: "1" }
  net.ipv4.tcp_keepalive_time: { expected: "600" }
  net.ipv4.tcp_keepalive_intvl: { expected: "30" }
  net.ipv4.tcp_keepalive_probes: { expected: "10" }

  # --- Connection backlog ---
  net.core.somaxconn: { expected: "32768" }
  net.core.netdev_max_backlog: { expected: "16384" }
  net.ipv4.tcp_max_syn_backlog: { expected: "8192" }

  # --- Conntrack
  # TODO: anomaly — common.yaml lowers below kernel default 262144 without rationale.
  # Tracked as separate observation issue (see #135 §Out of scope). Do not "fix" here.
  net.netfilter.nf_conntrack_max: { expected: "131072" }

  # --- ARP cache (gc_thresh tuned for ~6-node + pod-density mesh) ---
  net.ipv4.neigh.default.gc_thresh1: { expected: "1024" }
  net.ipv4.neigh.default.gc_thresh2: { expected: "2048" }
  net.ipv4.neigh.default.gc_thresh3: { expected: "4096" }

  # --- Filesystem & process limits ---
  fs.inotify.max_user_watches: { expected: "524288" }
  fs.inotify.max_user_instances: { expected: "8192" }
  fs.file-max: { expected: "2097152" }
  kernel.pid_max: { expected: "4194304" }

  # --- ICMP hardening ---
  net.ipv4.icmp_echo_ignore_broadcasts: { expected: "1" }
  net.ipv4.icmp_ignore_bogus_error_responses: { expected: "1" }

  # --- SYN flood + RFC1337 TIME-WAIT assassination protection ---
  net.ipv4.tcp_syncookies: { expected: "1" }
  net.ipv4.tcp_rfc1337: { expected: "1" }

  # --- ICMP redirect hardening (MITM prevention; v4 + v6, all + default) ---
  net.ipv4.conf.all.accept_redirects: { expected: "0" }
  net.ipv4.conf.default.accept_redirects: { expected: "0" }
  net.ipv4.conf.all.secure_redirects: { expected: "0" }
  net.ipv4.conf.default.secure_redirects: { expected: "0" }
  net.ipv6.conf.all.accept_redirects: { expected: "0" }
  net.ipv6.conf.default.accept_redirects: { expected: "0" }
  net.ipv4.conf.all.send_redirects: { expected: "0" }
  net.ipv4.conf.default.send_redirects: { expected: "0" }

  # --- Source-route hardening (v4 + v6) ---
  net.ipv4.conf.all.accept_source_route: { expected: "0" }
  net.ipv4.conf.default.accept_source_route: { expected: "0" }
  net.ipv6.conf.all.accept_source_route: { expected: "0" }
  net.ipv6.conf.default.accept_source_route: { expected: "0" }

  # --- Martian-packet logging suppressed (Cilium BPF triggers false positives) ---
  net.ipv4.conf.all.log_martians: { expected: "0" }
  net.ipv4.conf.default.log_martians: { expected: "0" }

  # --- IPv6 router advertisement disabled (no IPv6 plane on this cluster) ---
  net.ipv6.conf.all.accept_ra: { expected: "0" }
  net.ipv6.conf.default.accept_ra: { expected: "0" }

  # --- Misc kernel hardening (sysrq off, core dumps to /bin/false) ---
  kernel.sysrq: { expected: "0" }
  kernel.core_pattern: { expected: "|/bin/false" }

  # --- Aspirational (not in common.yaml; accepted by CI as one-way diff) ---
  # Talos has no swap, but explicit-zero is hygiene against accidental swap activation.
  vm.swappiness: { expected: "0", advisory: true }
# layer3-baseline-yaml-end
```

---

## Severity Rules (applied by SKILL)

1. If `actual == expected` (after trim + whitespace-collapse) → status `OK`.
2. Else if drift detected:
   - Layer 1 → status `CRITICAL`, finding `"<param>: expected <expected>, actual <actual> (layer=1 universal)"`.
   - Layer 2 → status `WARNING`, finding `"<param>: expected <expected>, actual <actual> (layer=2 talos-kspp)"`.
   - Layer 3 with `advisory: false` (default) → status `WARNING`, finding `"<param>: expected <expected>, actual <actual> (layer=3 cluster-tuning)"`.
   - Layer 3 with `advisory: true` → status `INFO`, finding `"<param>: aspirational <expected>, actual <actual> (layer=3 advisory)"`.
3. Per-node verdict precedence: `CRITICAL > WARNING > HEALTHY`. `INFO` and `OK` collapse to `HEALTHY`.

### Comparison Notes

- `tcp_rmem` / `tcp_wmem` / `ip_local_port_range` are tuples (e.g. `min default max`). Compare after collapsing whitespace to single spaces and trimming. Drift in any tuple value triggers the rule.
- All other values are scalar. Compare as trimmed strings — kernel exposes integers as text in `/proc/sys/`.
- Absent file (read returns precondition error) → record `actual: null`, status `PRECONDITION_NOT_MET`, do not raise the node-level verdict (already handled by per-node `PRECONDITION_NOT_MET` aggregation in SKILL.md §7).

---

## Maintenance

**Layer 1**: stable across kernel releases. Update only when the underlying Linux/K8s/Cilium prerequisite changes (e.g. Cilium drops the rp_filter requirement after a BPF datapath rewrite). Cite the upstream change in the commit body.

**Layer 2**: pinned to **Talos v1.12.6**. After every Talos minor upgrade (e.g. 1.12 → 1.13), re-run a snapshot and update Layer 2 in the same PR as the upgrade:

```bash
mcp__talos__talos_get KernelParamStatus nodes=[<one CP node IP>]
# Diff the spec.current values against §Layer 2 above; update entries where Talos changed defaults.
```

The `/plan-talos-upgrade` skill checklist references this step. If Layer-2 drifts (operator forgets to re-snapshot), the SKILL emits false WARNING findings on every audit — eroding signal trust.

**Layer 3**: **never edit by hand**. Always edit `talos/patches/common.yaml` first, then update Layer 3 to match in the same PR. CI (`sysctl-baseline-check.yml`) blocks merge if they diverge.

---

## Tuning Workflow

1. Run `/kernel-param-auditor --save-baseline` after a clean post-upgrade reconciliation to capture the live snapshot.
2. If a parameter consistently fires WARNING on a healthy cluster, decide which layer owns it:
   - K8s/Cilium-required → Layer 1 (will stay CRITICAL)
   - Talos KSPP default → Layer 2
   - Repo-specific cluster tuning → Layer 3 (also update `common.yaml`)
3. Never silently lower CRITICAL Layer-1 thresholds — escalate via the team-red review process for any change touching Layer 1.
