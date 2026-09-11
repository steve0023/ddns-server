# Self-hosted DDNS: authoritative BIND 9 in Docker + per-router TSIG keys

Give a fleet of routers with dynamic public IPs stable, publicly resolvable names,
without relying on a third-party DDNS provider.

A subdomain is delegated to an authoritative-only BIND 9 container. Each router gets
its own TSIG key, scoped by `update-policy` so it can rewrite **only its own A record**.
Routers update it with standard RFC 2136 (`nsupdate`), which most router firmware
supports natively — this was built and tested with Teltonika RutOS, but nothing here
is vendor-specific.

## Contents

| File | What it does |
| --- | --- |
| `install-ddns-server.sh` | Builds and verifies the whole server side. Idempotent; `--check` audits without changing anything. |
| `ddns-router` | Adds, removes, lists routers: generates each key, regenerates BIND's config, reloads, prints the settings to enter on the device. |

## Quick start

1. Edit the configuration block at the top of `install-ddns-server.sh` (zone,
   nameserver name, public IP, the VM's LAN IP, owning user).
2. `sudo ./install-ddns-server.sh` — with `ddns-router` in the same folder.
3. At your DNS host, in the **parent** zone, add the two records the installer
   prints at the end (an `A` for the nameserver, an `NS` delegating the subzone).
4. Forward port 53/udp+tcp from your router to the VM.
5. `sudo ddns-router add <name>` and enter the printed settings on the device.

The installer's closing output lists steps 3 to 5 with the exact commands and the
traps worth knowing about. Re-run it any time; `--check` is the post-restore audit.

## Design

- **Authoritative only.** `recursion no`, response rate limiting, minimal responses:
  not usable as an open resolver or an amplifier.
- **Least privilege per router.** `grant <key> name <host>.<zone>. A;` — a leaked
  router key cannot touch another router's record, or anything else in the zone.
- **Hardened container.** Read-only filesystem, all capabilities dropped, no new
  privileges, tmpfs for the few writable paths, memory and PID limits.
- **No outbound connections.** An authoritative server only ever answers. iptables
  rules on the container's bridge drop anything it initiates, covering both the
  forwarded path and the host itself. The installer verifies this rather than
  assuming it — and reports `UNTESTED` rather than success if it cannot.
- **Single source of truth.** `config/routers.list` drives a generated `ddns.conf`;
  every change is validated with `named-checkconf` and rolled back if rejected.

## Requirements

Docker with the iptables backend (the `DOCKER-USER` chain must exist), a static
public IP, port 53 free on the host, and a domain whose parent zone you can edit.

## Client-side notes (Teltonika RutOS)

Found the hard way; may apply to other OpenWrt-derived firmware:

- **Firmware 07.20 or newer.** Earlier versions truncate a multi-level subdomain to
  its first label and every update fails with `NOTAUTH`.
- **The username needs the algorithm prefix**, `hmac-sha256:<keyname>`. Without it
  the bundled `snsupdate` segfaults and nothing is sent.
- **The DNS server field takes an IP only.** A hostname is rejected by the update
  script itself (`sanitize ... outside allowed subset`), not just the web UI.
- **"Update successful" in the router log is meaningless.** `update_nsupdate.sh`
  ends with an unconditional `return 0`, so it reports success even when the updater
  crashed or the server rejected the request. Verify on the server:
  `docker compose logs bind9 | grep "key <name>"`, or `dig <name>.<zone> @1.1.1.1`.

## Licence

MIT.
