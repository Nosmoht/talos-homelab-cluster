# Talos Maintenance API — Reference for discover-maintenance-node

## What is maintenance mode

A freshly-booted Talos node (post-PXE / -USB / -firstboot-Factory-image, pre-config-apply) runs the
**maintenance** Machine API: same gRPC surface, but with no TLS material — listening on the node's
LAN IP with self-signed cert and no client auth. The talosctl client reaches it via the
`--insecure` (or `-i`) flag, which skips client-cert presentation and accepts the server's
self-signed cert.

This window closes the moment a config is applied (`talosctl apply-config --insecure`): the node
then pins its identity to the cluster PKI and the maintenance API is sealed off.

## Verified subcommands available in maintenance mode

Probed against this repo's `talos-mcp@2.3.3` + upstream Talos v1.12.x talosctl client:

| Operation | Command | Notes |
|---|---|---|
| Version + uptime | `talosctl version --nodes <ip> --insecure` | top-level `--insecure` flag |
| Disk inventory | `talosctl get -i disks --nodes <ip> -o yaml` | subcommand-level `-i` |
| Link inventory | `talosctl get -i links --nodes <ip> -o yaml` | subcommand-level `-i` |
| Apply initial config | `talosctl apply-config --insecure --nodes <ip> --file <config>` | `make install-<node>` invokes this |

Other `talosctl get -i <type>` subtypes may work — verify upstream before relying on them in this
skill (Talos COSI resource discovery is the authoritative listing: `talosctl get rd`, but that
itself is not guaranteed in maintenance mode).

## Why MCP cannot reach maintenance mode

`talos-mcp` (v2.3.3) is a thin wrapper around the Machine API client. Inspection of the startup
log confirms it loads the active `talosconfig` and uses TLS — there is no `--insecure` path in
the surfaced tool schemas. The MCP server cannot reach a fresh node, and forcing a fallback to
insecure transport at the MCP layer would be a security regression.

Decision (per `.claude/rules/talos-mcp-first.md` CLI-Only table): all maintenance-mode probes
are CLI-only. The CLI fallback is documented inline in the skill phases.

## NIC-driver → hardware mapping (homelab-specific hints)

Used to validate Probe 3 output against expected hardware classes:

| Driver | Typical hardware |
|---|---|
| `e1000e` | Intel 82579V / I217-LM / I218-V / I219-V — built-in NIC on Lenovo ThinkCentre M910q / M920q |
| `r8152` | Realtek RTL8153 — USB-attached Gigabit NIC (node-gpu-01 carries one; out of scope for this skill) |
| `igc` | Intel I225-V / I226-V — newer Mini-PC / SFF generation; rare in current homelab inventory |

If Probe 3 reports a driver not in this table, the new node is hardware-unusual — pause and
document it (e.g. note in `docs/hardware-analysis-<node>.md`) before proceeding to render.

## When to abort the skill

- Probe 1 fails with TLS or auth error → node is NOT in maintenance mode (already configured, or
  someone partly applied a config). Stop and consult `talos_reset` runbook in
  `.claude/skills/onboard-worker-node/references/runbook.md`.
- Probe 2 returns no disks or fewer than expected → node hardware fault or USB-only boot media.
- Probe 3 reports an unexpected driver (see table) → pause to update hardware inventory before
  rendering with potentially wrong assumptions.
- Computed DRBD host-octet ≤ 0 or ≥ 255 → LAN host-octet is outside the supported scheme range.
  Decide deliberately whether to extend the scheme or use a different LAN octet.

## See also

- `.claude/rules/talos-config.md §DRBD Replication VLAN` — IP scheme rationale
- `.claude/rules/talos-config.md §Patch Inheritance Matrix` — what patches apply to which role
- `.claude/rules/talos-mcp-first.md §CLI-Only` — exhaustive list of CLI-only Talos operations
- `talos/nodes/_template.yaml.tmpl` — the rendered output target
