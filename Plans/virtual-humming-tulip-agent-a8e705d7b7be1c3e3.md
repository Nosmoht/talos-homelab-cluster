# Deep Research: NIC Naming with `net.ifnames=0` on Mixed PCIe + USB NIC System

## Context

**node-gpu-01** has two NICs:
- **PCIe NIC:** Realtek RTL8136 at PCI BDF `0000:04:00.0`, driver `r8169`, currently `enp4s0` -- INACTIVE (link down)
- **USB NIC:** Realtek RTL8153 on USB 3.0 (xHCI at PCI `0000:00:14.0`), driver `r8152`, currently `enp0s20f0u2` -- ACTIVE (only working network)

---

## Q1: Which interface gets `eth0` and which gets `eth1`?

**Answer: The PCIe NIC (r8169) will MOST LIKELY get `eth0`, but this is NOT guaranteed.**

### Reasoning

With `net.ifnames=0`, the kernel reverts to legacy sequential naming: the first NIC to call `register_netdevice()` gets `eth0`, the second gets `eth1`, and so on. The assignment depends entirely on **driver probe order**.

Both `r8169` (PCI) and `r8152` (USB) use the `device_initcall` level (level 6) via the `module_pci_driver()` and `module_usb_driver()` macros respectively. However, the **bus subsystem initialization** matters more:

1. **PCI bus scanning** happens at `subsys_initcall` (level 4) via `pci_driver_init()`.
2. **USB core initialization** also happens at `subsys_initcall` (level 4) via `usb_init()`.
3. Within the same initcall level, **kernel link order** determines execution sequence.

In practice, PCI bus scanning is a **synchronous, deterministic, breadth-first walk** of the PCI topology. The r8169 driver matches `0000:04:00.0` directly during PCI probe. USB device discovery, by contrast, is **asynchronous** -- the xHCI controller at `0000:00:14.0` is itself a PCI device that gets probed, but then USB hub enumeration happens asynchronously afterward. The USB NIC behind it is only discovered after the hub completes enumeration.

**In most kernel configurations, PCI device drivers complete probe before USB devices finish enumeration.** This means:
- `eth0` = PCIe NIC (r8169, the INACTIVE one)
- `eth1` = USB NIC (r8152, the ACTIVE one)

### Sources
- [Dell NIC Enumeration Whitepaper v4.1](https://linux.dell.com/files/whitepapers/nic-enum-whitepaper.pdf)
- [Red Hat RHEL 8 - Consistent Network Device Naming](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/configuring_and_managing_networking/consistent-network-interface-device-naming_configuring-and-managing-networking)
- [Collabora - Introduction to Linux Kernel Initcalls](https://www.collabora.com/news-and-blog/blog/2020/07/14/introduction-to-linux-kernel-initcalls/)
- [LWN - Network Device Naming mechanism and policy](https://lwn.net/Articles/325131/)

---

## Q2: Is the assignment deterministic across reboots?

**Answer: PROBABLY yes on this specific hardware, but NOT guaranteed by the kernel.**

### Reasoning

The kernel documentation and every major distribution explicitly state that legacy `ethX` naming is **non-deterministic**. This is the entire reason predictable naming was invented.

However, in practice, on a specific unchanging hardware configuration:
- PCI topology enumeration IS deterministic (breadth-first by BDF).
- If both drivers are built-in (not modules), their probe order is determined by link order, which is fixed for a given kernel binary.
- USB device discovery timing can vary by milliseconds between boots.

**The risk**: If the USB NIC happens to enumerate faster on one boot (e.g., due to PCI link training delays on the RTL8136), the assignment could flip. This is exactly the race condition that predictable naming was designed to solve.

**Verdict: Do NOT rely on `eth0`/`eth1` assignment being stable across reboots for a production system.**

### Sources
- [Debian Wiki - NetworkInterfaceNames](https://wiki.debian.org/NetworkInterfaceNames): "if module probes completed in a different order, eth0 and eth1 might switch places on successive boots"
- [freedesktop.org - PredictableNetworkInterfaceNames](https://www.freedesktop.org/wiki/Software/systemd/PredictableNetworkInterfaceNames/)
- [Dell NIC Enumeration Whitepaper](https://linux.dell.com/files/whitepapers/nic-enum-whitepaper.pdf)

---

## Q3: Does the PCIe NIC always enumerate before USB devices?

**Answer: In MOST cases yes, but not by specification -- it is an implementation artifact.**

### Reasoning

- PCI bus scanning is a synchronous, recursive walk starting from the root complex. The kernel discovers `0000:04:00.0` (r8169) directly during this walk.
- The xHCI USB controller at `0000:00:14.0` is ALSO discovered during PCI scanning. But the USB NIC behind it requires a second asynchronous step: USB hub enumeration + device identification.
- Both the PCI subsystem (`pci_driver_init`) and USB subsystem (`usb_init`) use `subsys_initcall` (level 4). Within the same level, execution order depends on link order in the kernel binary.
- The r8169 driver's `probe()` function runs during PCI device matching. The r8152 driver's `probe()` only runs AFTER the USB hub has completed asynchronous enumeration of its ports.

**Net effect**: The PCI NIC typically registers its netdevice BEFORE the USB NIC, because USB enumeration adds latency. But this is a timing-dependent implementation detail, not a kernel guarantee.

### Sources
- [Linux Kernel PCI Documentation](https://docs.kernel.org/PCI/index.html)
- [Code of Connor - How the Linux Kernel Detects PCI Devices](https://codeofconnor.com/how-the-linux-kernel-detects-pci-devices-and-pairs-them-with-their-drivers/)
- [LWN - Initcall Depends](https://lwn.net/Articles/2615/)

---

## Q4: Could the inactive PCIe NIC get `eth0` even though it's link-down?

**Answer: YES. Link state has absolutely no effect on interface naming.**

### Reasoning

Interface naming happens at **device registration time**, which occurs when the driver's `probe()` function calls `register_netdev()`. This happens when the kernel discovers the hardware, regardless of whether a cable is plugged in or the link is up.

Link state (carrier up/down) is a runtime property that changes after the interface is registered and named. A NIC with no cable, no link partner, or a failed PHY will still:
1. Be discovered by PCI bus scanning
2. Have its driver probe successfully
3. Get assigned an `ethX` name
4. Report `NO-CARRIER` or `link down` in its operational state

**This means the inactive PCIe NIC WILL likely get `eth0`, and the active USB NIC will get `eth1`.** If macvlan is configured with `master: eth0`, it would attach to the WRONG (dead) interface.

### Sources
- [Red Hat - Troubleshooting Network Device Naming](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/networking_guide/sec-troubleshooting_network_device_naming)
- [Linux Device Drivers 3rd Ed - Chapter 17: Network Drivers](https://www.oreilly.com/library/view/linux-device-drivers/0596005903/ch17.html)

---

## Q5: Does the macvlan CNI plugin support selecting master by anything other than interface name?

**Answer: NO. The macvlan CNI plugin ONLY accepts interface name via the `master` parameter.**

### Configuration Parameters (exhaustive)
| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string, required | Network name |
| `type` | string, required | "macvlan" |
| `master` | string, optional | **Name of host interface** (e.g., `eth0`). Defaults to default route interface. |
| `mode` | string, optional | bridge/private/vepa/passthru (default: bridge) |
| `mtu` | integer, optional | MTU value |
| `ipam` | dict, required | IPAM configuration |
| `linkInContainer` | boolean, optional | Whether master is in container namespace |

There is **no support** for MAC address, PCI address, driver name, or any other hardware identifier. The `master` field is a plain interface name string.

### Sources
- [CNI macvlan plugin documentation](https://www.cni.dev/plugins/current/main/macvlan/)
- [containernetworking/plugins - macvlan.go source](https://github.com/containernetworking/plugins/blob/main/plugins/main/macvlan/macvlan.go)

---

## Q6: Are there CNI plugins that CAN select interface by MAC or PCI slot?

**Answer: YES -- the `host-device` CNI plugin supports multiple identification methods.**

### host-device plugin identification methods
| Parameter | Example | Description |
|-----------|---------|-------------|
| `device` | `eth0` | Interface name |
| `hwaddr` | `00:e0:3c:68:46:45` | MAC address |
| `kernelpath` | `/sys/devices/pci0000:00/0000:00:1f.6` | Sysfs kernel device path |
| `pciBusID` | `0000:00:1f.6` | PCI BDF address |
| `deviceID` | `0000:00:1f.6` | PCI address via runtime config (for Multus integration) |

**CRITICAL DIFFERENCE**: The `host-device` plugin **moves the entire host interface into the pod's network namespace**. This is fundamentally different from macvlan, which creates a virtual sub-interface. Moving the host's primary network interface into a pod would break the node's network connectivity.

The **SR-IOV CNI plugin** also supports PCI address-based device selection, but requires SR-IOV capable hardware (which the RTL8136/RTL8153 are not).

**Neither of these alternatives solves the macvlan use case** where you need to create virtual interfaces on top of the host's primary NIC while identifying it by MAC/PCI.

### Sources
- [CNI host-device plugin documentation](https://www.cni.dev/plugins/current/main/host-device/)
- [containernetworking/plugins - host-device issue #253](https://github.com/containernetworking/plugins/issues/253)
- [SR-IOV Network Device Plugin](https://github.com/k8snetworkplumbingwg/sriov-network-device-plugin)

---

## Q7: In Talos Linux specifically, are there mechanisms to assign custom interface names?

**Answer: Talos has `deviceSelector` for its own config, but CANNOT rename interfaces for CNI plugins.**

### What Talos CAN do

Talos `machine.network.interfaces` supports `deviceSelector` with these fields:
- `hardwareAddr` -- MAC address (recommended, globally unique)
- `permanentAddr` -- permanent MAC (survives bonding)
- `busPath` -- PCI bus path (e.g., `0000:04:00.0`)
- `pciID` -- PCI vendor:device ID
- `driver` -- kernel driver name (e.g., `r8152`)
- `physical` -- boolean, physical devices only

**node-gpu-01 already uses this**: `hardwareAddr: 00:e0:3c:68:46:45` in `talos/nodes/node-gpu-01.yaml`. This correctly selects the USB NIC regardless of its ethX/enpXsY name.

### What Talos CANNOT do

1. **No udev rename support**: Talos GitHub Discussion #8018 confirms that udev user rules are applied "too late" -- the Talos network stack is already running and opening links. Attempting `ip link set name` fails with "Resource busy".

2. **No systemd .link files**: Talos does not use systemd-networkd for interface management. There is no mechanism to create custom `.link` files that would rename interfaces.

3. **`net.ifnames=0` is the only naming control**: This is a binary choice -- predictable names (on by default) or legacy ethX names. There is no way to assign specific custom names.

### The Gap

Talos `deviceSelector` works perfectly for Talos's own network configuration. But CNI plugins like macvlan run OUTSIDE Talos's config system -- they operate directly on Linux netdevices by name. Talos provides no mechanism to ensure a specific interface has a specific name for CNI consumption.

### Sources
- [Talos - Network Device Selector](https://docs.siderolabs.com/talos/v1.9/networking/device-selector/)
- [Talos - Predictable Interface Names](https://docs.siderolabs.com/talos/v1.9/networking/predictable-interface-names)
- [Talos GitHub Discussion #8018 - Setting network interface name via udev rules](https://github.com/siderolabs/talos/discussions/8018)

---

## Summary and Implications

### The Core Problem

Using `net.ifnames=0` to get a simple `eth0` name for macvlan is **dangerous** on this node because:

1. **The WRONG NIC will likely get `eth0`**: The inactive PCIe NIC (r8169) will almost certainly probe before the active USB NIC (r8152), claiming `eth0`. The active USB NIC becomes `eth1`.
2. **The assignment is not guaranteed stable**: Even if it works on one boot, kernel or firmware updates could change probe order.
3. **Link state does not affect naming**: The dead PCIe NIC gets named first regardless.

### Viable Alternatives

| Approach | Feasibility | Risk |
|----------|-------------|------|
| Use predictable names (current: `enp0s20f0u2`) in macvlan `master` | Works today | Name could change if USB port changes |
| Use `net.ifnames=0` and hardcode `eth1` | Fragile | Probe order could flip |
| Omit `master` in macvlan (uses default route interface) | Simple | Assumes active NIC is always default route |
| Write a custom CNI meta-plugin that resolves MAC to name | Reliable | Engineering effort |
| Use `host-device` CNI with `hwaddr` | Reliable identification | Moves interface into pod (breaks host networking) |

### Recommendation

**Do NOT use `net.ifnames=0` for this purpose.** The safest approaches are:
1. **Keep predictable names and use `enp0s20f0u2` as the macvlan master** -- this name is derived from the USB topology path and is stable as long as the NIC stays in the same USB port.
2. **Omit the `master` field entirely** -- macvlan defaults to the default route interface, which on this single-active-NIC node will always be the USB NIC.
3. If the name feels fragile, investigate writing a **thin init container or DaemonSet** that resolves MAC address to current interface name and patches the NetworkAttachmentDefinition.
