# Link-Flap Failure Patterns

Reference data used by `link-flap-detector` to classify per-node verdicts and emit
correlation findings.

## Signal Sources

The skill correlates two independent signals per node:

| Signal | Source | Captures |
|---|---|---|
| `carrier_changes` | `/sys/class/net/<iface>/carrier_changes` | Lifetime count of link state transitions since boot. Each up→down→up cycle is two transitions. |
| `dmesg_events` | `talos_dmesg` filtered by `link is down\|link is up\|carrier` | Timestamped kernel events within the analysis window. |

Two signals exist because they answer different questions:
- `carrier_changes` is **cheap** (single sysfs read), gives **lifetime totals**, no timestamps.
- `dmesg_events` is **timestamped** (cross-node correlation possible), but only covers what is
  still in the kernel ring buffer (typically minutes to hours, not days).

## Window Semantics

`--window <duration>` (default `1h`) bounds the dmesg event count and the cross-node correlation
search. It does **not** bound `carrier_changes` — that counter is always lifetime since boot.

Accepted forms: `5m`, `30m`, `1h`, `6h`, `24h`. Parser converts to seconds for dmesg timestamp
filtering.

## Per-Interface Severity Rules

Apply per (node, interface). Worst interface verdict becomes the node verdict.

| Condition | Verdict |
|---|---|
| `carrier_changes == 0` AND `dmesg_event_count == 0` | HEALTHY |
| `carrier_changes` in `1..2` (lifetime) AND `dmesg_event_count == 0` | HEALTHY (likely from boot/initial bring-up) |
| `dmesg_event_count` in `1..2` within window AND no cross-node correlation | WARNING |
| `carrier_changes >= 3` (lifetime) on a node up < 24h | WARNING |
| `dmesg_event_count >= 3` within window | CRITICAL |
| Cross-node correlated flap (≥ 2 nodes within 5 s) | CRITICAL |

`carrier_changes` lifetime totals on long-running nodes drift: a node up for 90 days with 4 flaps
is much less alarming than a node up 1 hour with 4 flaps. Where uptime is unknown, prefer
`dmesg_event_count` within window as the primary signal — `carrier_changes` is the secondary
sanity check.

## Cross-Node Correlation

After collecting per-node `events[]` (each `{timestamp, iface, direction}`), run a sliding
5-second window across all events from all nodes. Any window containing events from ≥ 2 distinct
nodes is a **correlation cluster**.

For each cluster, emit a finding to **every involved node**:

```
"simultaneous flap on N1 and N2 at <ISO-8601> — likely upstream switch issue, not local NIC"
```

The 5-second window absorbs clock skew between nodes (typically < 1 s under chrony) and dmesg
buffering. Tune up to 10 s if cluster nodes have clock drift > 2 s; tune down to 2 s if false
positives appear.

## Direction Heuristics

Parse the dmesg line into `direction ∈ {down, up, carrier-loss, carrier-gain}`:

| dmesg substring | direction |
|---|---|
| `link is down` | `down` |
| `link is up` | `up` |
| `Link is Down` (capitalized; Intel e1000) | `down` |
| `Link is Up` | `up` |
| `NIC Link is Up` | `up` |
| `carrier lost` | `carrier-loss` |
| `carrier gained` (rare) | `carrier-gain` |

Capture verbatim line in `events[].raw` for human inspection; the structured `direction` is the
machine-classifiable subset.

## Root-Cause Hint Patterns

Append these to per-node `findings[]` when the underlying conditions are observed (independent of
severity):

| Pattern | Hint |
|---|---|
| Cross-node correlation cluster (≥ 2 nodes, 5 s window) | `"simultaneous flap on <nodes> at <ts> — likely upstream switch issue or VLAN-trunk reconverge"` |
| Single node, ≥ 3 events in window, all on same iface | `"repeated flap on <node>:<iface> — likely cable, SFP, or NIC port issue (local fault)"` |
| Single node, alternating up/down within < 5 s | `"rapid up/down on <node>:<iface> — duplex or autoneg mismatch suspected"` |
| `carrier_changes` lifetime ≥ 10 but no events in window | `"carrier_changes=<n> historic, no recent flaps in window — past issue, monitor only"` |
| dmesg buffer empty (`dmesg_event_count == 0`) but `carrier_changes > 0` | `"carrier_changes=<n> seen but dmesg buffer empty — events older than ring-buffer retention; rerun closer to incident"` |

## Correlation Examples

| Scenario | Expected output |
|---|---|
| Switch port flaps, two nodes on same switch | Both nodes CRITICAL with simultaneous-flap finding citing each other |
| Single bad cable on `node-04` | `node-04` CRITICAL, isolated finding "repeated flap on node-04:eth0 — likely cable" |
| Cluster-wide reboot (all nodes flap during STP reconverge) | All nodes WARNING (boot-time transitions absorbed by HEALTHY rule when flap count ≤ 2) |
| `node-pi-01` only — Pi USB NIC reset | `node-pi-01` CRITICAL/WARNING isolated, no correlation with x86 nodes |

## Tuning

Starting thresholds reflect a homelab cluster with ≤ 10 nodes and stable wired links. After a few
weeks of real use:

- If WARNING fires excessively on healthy clusters with long uptime, raise the lifetime
  `carrier_changes` WARNING gate to `>= 5`.
- If correlation false-positives at 5 s window, drop to 3 s — but only after verifying chrony
  sync is < 500 ms.
- Document tuning rationale in this file's git history; do not silently mutate thresholds.
