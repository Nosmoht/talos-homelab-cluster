# Critical Review: nginx Stream Configuration in Step 4

## Configuration Under Review

```nginx
worker_processes 1;
events { worker_connections 512; }
stream {
  resolver kube-dns.kube-system.svc.cluster.local valid=30s;
  map "" $gw_backend {
    default cilium-gateway-homelab-gateway.default.svc.cluster.local;
  }
  server {
    listen 192.168.2.70:80;
    proxy_pass $gw_backend:80;
  }
  server {
    listen 192.168.2.70:443;
    proxy_pass $gw_backend:443;
  }
}
```

---

## Finding 1: `resolver` directive in `stream {}` -- VALID but has a critical problem

**The `resolver` directive IS valid in stream context** (since nginx 1.11.3). The official `ngx_stream_core_module` documentation confirms it accepts the same parameters as the http module version: `resolver address ... [valid=time] [ipv4=on|off] [ipv6=on|off]`.

**HOWEVER: using a hostname for the resolver address creates a circular dependency.** The `resolver` directive tells nginx which DNS server to use for resolving hostnames. If the resolver address itself is a hostname (`kube-dns.kube-system.svc.cluster.local`), nginx needs to resolve THAT hostname first -- but it has no resolver configured yet to do so. This is a chicken-and-egg problem.

While the nginx documentation technically says `address` can be "a domain name or IP address", in practice using a domain name for the resolver requires the system resolver (`/etc/resolv.conf`) to resolve it at config load time. In a Kubernetes pod, `/etc/resolv.conf` points to the kube-dns ClusterIP (typically `10.96.0.10`), so nginx might resolve it at startup. But this is fragile and adds an unnecessary indirection.

**Fix:** Use the kube-dns ClusterIP directly:
```nginx
resolver 10.96.0.10 valid=30s;
```
Verify the actual ClusterIP with `kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}'`.

**Severity: MEDIUM-HIGH.** May work by accident (system resolver fallback) but is semantically wrong and fragile. If nginx cannot resolve the hostname at startup, it will fail to load the config entirely.

---

## Finding 2: `map "" $variable` trick -- INVALID SYNTAX

The `map` directive in the stream module (available since 1.11.2) has the syntax: `map string $variable { ... }`. The first parameter is the source value to match against. An empty string `""` is not a valid source -- it evaluates to nothing, and there is no input value to match patterns against.

The correct patterns documented in the wild are:

**Option A -- map with a real variable (preferred for stream):**
```nginx
map $remote_addr $gw_backend {
    default cilium-gateway-homelab-gateway.default.svc.cluster.local;
}
```
This maps against `$remote_addr` (always has a value for any connection), so `default` always matches. The result is a variable that triggers dynamic DNS resolution.

**Option B -- set directive (nginx >= 1.19.3):**
Since the plan uses `nginx:1.27-alpine`, the `set` directive IS available in stream server blocks (added in 1.19.3):
```nginx
server {
    listen 192.168.2.70:80;
    set $gw_backend cilium-gateway-homelab-gateway.default.svc.cluster.local;
    proxy_pass $gw_backend:80;
}
```
This is the cleaner, more idiomatic approach for nginx 1.27.

**Severity: HIGH.** The `map "" $variable` syntax will likely cause a config parse error and prevent nginx from starting, causing a crash loop.

---

## Finding 3: `listen` on an IP that may not exist at startup -- NOT A PROBLEM in Kubernetes

In traditional Linux, if nginx tries to `bind()` to an IP not assigned to any interface, it fails with `EADDRNOTAVAIL` ("Cannot assign requested address") and refuses to start. The workaround is `net.ipv4.ip_nonlocal_bind=1`.

**However, in Kubernetes with Multus, this is NOT an issue.** The CNI spec requires all network plugins (including Multus-delegated plugins like macvlan) to execute during pod sandbox creation, BEFORE any containers start. The kubelet/CRI sequence is:
1. Create pod network namespace
2. Execute ALL CNI plugins (primary Cilium + secondary macvlan via Multus)
3. Start init containers
4. Start regular containers

By the time the nginx container process starts, the macvlan `net1` interface with IP `192.168.2.70` is already configured in the pod's network namespace. If the macvlan CNI plugin fails (e.g., master interface missing), the pod stays in `ContainerCreating` -- the container never starts at all.

**Severity: NONE.** This is safe in Kubernetes. The concern would only apply to bare-metal nginx or if there were a race condition in the CNI plugin, which Multus handles synchronously.

---

## Finding 4: `proxy_pass $gw_backend:80` syntax -- VALID

This was confirmed working by Maxim Dounin (nginx maintainer) in [nginx ticket #1220](https://trac.nginx.org/nginx/ticket/1220). The example he provided:

```nginx
stream {
    resolver 127.0.0.1;
    map $remote_addr $backend {
        default foo.example.com;
    }
    server {
        listen 12345;
        proxy_pass $backend:12345;
    }
}
```

When `proxy_pass` contains a variable, nginx performs string interpolation: `$gw_backend` expands to the FQDN, then `:80` is appended as a literal, producing `cilium-gateway-homelab-gateway.default.svc.cluster.local:80`. This is then resolved using the configured `resolver`.

The variable-in-proxy_pass feature has been available since nginx 1.11.3 in the stream module.

**Severity: NONE.** The syntax is correct and well-documented.

---

## Finding 5: FQDN hostnames in stream `proxy_pass` -- VALID with resolver

The nginx stream `proxy_pass` documentation states: when the address contains a variable, "the server name is searched among the described server groups, and, if not found, is determined using a resolver."

So the resolution chain is:
1. Check if `$gw_backend` matches any `upstream {}` block name
2. If not, use the `resolver` to perform DNS resolution on the FQDN

Since there are no upstream blocks defined, nginx will use the resolver to look up `cilium-gateway-homelab-gateway.default.svc.cluster.local`, which will return the ClusterIP of the gateway service.

**Severity: NONE.** This works correctly with a properly configured resolver.

---

## Summary of Required Fixes

| # | Issue | Severity | Fix |
|---|-------|----------|-----|
| 1 | `resolver` uses hostname instead of IP | MEDIUM-HIGH | Use `10.96.0.10` (kube-dns ClusterIP) |
| 2 | `map "" $variable` is invalid syntax | HIGH | Use `set` (nginx 1.27 supports it) or `map $remote_addr` |
| 3 | Listen on macvlan IP before interface ready | NONE | CNI runs before container start |
| 4 | `proxy_pass $var:port` syntax | NONE | Confirmed valid by nginx maintainer |
| 5 | FQDN in stream proxy_pass | NONE | Works with resolver |

## Recommended Corrected Configuration

```nginx
worker_processes 1;
events { worker_connections 512; }
stream {
  resolver 10.96.0.10 valid=30s;
  server {
    listen 192.168.2.70:80;
    set $gw_backend cilium-gateway-homelab-gateway.default.svc.cluster.local;
    proxy_pass $gw_backend:80;
  }
  server {
    listen 192.168.2.70:443;
    set $gw_backend cilium-gateway-homelab-gateway.default.svc.cluster.local;
    proxy_pass $gw_backend:443;
  }
}
```

Changes:
- `resolver` now uses the kube-dns ClusterIP directly (no circular dependency)
- `map "" $variable` replaced with `set $variable` inside each server block (cleaner, idiomatic for nginx 1.27)
- `set` in stream server context requires nginx >= 1.19.3 (plan uses 1.27, so this is fine)

Sources:
- [nginx stream core module (resolver)](https://nginx.org/en/docs/stream/ngx_stream_core_module.html)
- [nginx stream proxy module (proxy_pass)](https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html)
- [nginx stream set module](https://nginx.org/en/docs/stream/ngx_stream_set_module.html)
- [nginx stream map module](https://nginx.org/en/docs/stream/ngx_stream_map_module.html)
- [nginx ticket #1220 - stream DNS re-resolution](https://trac.nginx.org/nginx/ticket/1220)
- [Variables in nginx stream module](https://sqds.medium.com/variables-in-nginx-stream-module-e099e609d240)
- [Dynamic DNS Resolution Open Sourced in NGINX](https://blog.nginx.org/blog/dynamic-dns-resolution-open-sourced-in-nginx)
