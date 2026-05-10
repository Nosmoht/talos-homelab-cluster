# NIC Sysfs Counter Thresholds

Canonical counter set read by `nic-health-audit` from `/sys/class/net/<iface>/statistics/`.

## Counters

| Counter | Meaning | Notes |
|---|---|---|
| `rx_packets` | RX packets ok | Sanity / liveness signal — not a verdict input |
| `tx_packets` | TX packets ok | Sanity / liveness signal — not a verdict input |
| `rx_errors` | All RX errors aggregated | Total RX failure count |
| `tx_errors` | All TX errors aggregated | Total TX failure count |
| `rx_dropped` | RX packets dropped (no buffer, policy, etc.) | Often ring-buffer-pressure indicator |
| `rx_crc_errors` | CRC mismatches on RX | Physical layer (cable, SFP, duplex mismatch) |
| `rx_frame_errors` | Frame alignment errors | Physical layer |
| `rx_missed_errors` | RX missed (HW queue full, NIC dropped) | Ring-buffer pressure when paired with `crc==0` |
| `collisions` | Collisions detected | Should be 0 on modern full-duplex switched networks |
| `carrier_changes` | Link state transitions since boot | Each transition is one up→down→up cycle |
| `tx_dropped` | TX packets dropped | Driver / queue saturation |

## Severity Rules — snapshot mode (no `--baseline`)

When called without `--baseline`, thresholds apply to absolute (lifetime since boot) values. These are conservative — long-running nodes may legitimately have non-zero counters.

| Counter | WARNING threshold | CRITICAL threshold |
|---|---|---|
| `rx_crc_errors` | `> 0` | `> 100` |
| `rx_frame_errors` | `> 0` | `> 100` |
| `carrier_changes` | `> 2` | `> 10` |
| `collisions` | `> 0` (any on switched net) | `> 100` |
| `rx_errors` | `> 10` | `> 1000` |
| `tx_errors` | `> 10` | `> 1000` |
| `rx_missed_errors` | `> 0` | `> 1000` |
| `rx_dropped` | `> 100` | `> 10000` |
| `tx_dropped` | `> 100` | `> 10000` |

Interface verdict = worst-of all counters on that interface. Node verdict = worst-of all interface verdicts.

## Severity Rules — baseline-diff mode (with `--baseline`)

When called with `--baseline <path>`, thresholds apply to the delta (`current - baseline`) over the elapsed time. More sensitive, lower noise floor.

| Counter | WARNING delta | CRITICAL delta |
|---|---|---|
| `rx_crc_errors` | `> 0` | `> 10` |
| `rx_frame_errors` | `> 0` | `> 10` |
| `carrier_changes` | `> 0` (any new flap) | `> 3` |
| `collisions` | `> 0` | `> 10` |
| `rx_errors` | `> 5` | `> 100` |
| `tx_errors` | `> 5` | `> 100` |
| `rx_missed_errors` | `> 0` | `> 100` |
| `rx_dropped` | `> 50` | `> 1000` |
| `tx_dropped` | `> 50` | `> 1000` |

Negative deltas (current < baseline) indicate a counter wrap or NIC reset; report as `"counter wrap detected — baseline stale"` and skip threshold check for that counter.

## Root-Cause Hint Patterns

Append these to `findings[]` when the underlying conditions are observed (independent of severity):

| Pattern | Hint string |
|---|---|
| `carrier_changes > 0` | `"carrier_changes=N — link flap candidate, run /link-flap-detector for details"` |
| `rx_missed_errors > 0 && rx_crc_errors == 0` | `"rx_missed=N, crc=0 — ring buffer pressure, candidate for ring-buffer tuning (Phase 1b #100)"` |
| `rx_crc_errors > 0` | `"rx_crc=N — physical layer issue (cable, SFP, or duplex mismatch)"` |
| `collisions > 0` | `"collisions=N on switched network — duplex mismatch likely; check switch port and NIC negotiation"` |
| `rx_dropped > 0 && rx_missed_errors == 0` | `"rx_dropped=N without rx_missed — likely policy drop (CNI), not buffer pressure"` |

## Cross-Node Outlier Detection

After per-node verdict, compute:
- `mean(counter)` and `stddev(counter)` across all audited nodes (population stddev, not sample)
- For each (node, iface, counter), if `value > mean + 2*stddev` AND `value > 10` (noise floor): emit finding `"<counter>=N is N.Nσ above cluster mean — outlier"`

Outlier alone does not raise verdict. It promotes WARNING to CRITICAL only if the outlier counter is in: `rx_errors`, `tx_errors`, `rx_crc_errors`, `carrier_changes`.

## Tuning

These thresholds are starting values from public sysadmin guidance and Linux kernel documentation. After Phase 1a stable and a few weeks of real use:
- If WARNING fires excessively on healthy clusters, raise the WARNING threshold by 5×
- If CRITICAL never fires on actually-broken NICs, lower the CRITICAL threshold by 5×
- Document tuning rationale in this file's git history; do not silently mutate thresholds
