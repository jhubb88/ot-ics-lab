# Phase 2 Scenario 1 — Reconnaissance (nmap) of `ot_zone`

**Date:** 2026-05-22
**Source task:** Phase 2 attack scenarios (step 2 of Phase 2)
**Attacker vantage:** `otlab-attacker`, multi-homed on `attacker_zone`
(172.20.0.2) + `ot_zone` (172.18.0.4) after `docker network connect
otlab_ot_zone otlab-attacker`.

---

## Setup

Phase 2 step 1 left the attacker isolated on `attacker_zone`. For this
task we intentionally cross the boundary at runtime — no compose edit —
so the act of crossing is itself visible and reversible:

```bash
docker network connect otlab_ot_zone otlab-attacker
```

Post-attach state inside the attacker container:

```
2: eth0  172.20.0.2/16   (attacker_zone, original)
3: eth1  172.18.0.4/16   (ot_zone, just attached)

default via 172.20.0.1 dev eth0
172.18.0.0/16 dev eth1 proto kernel scope link src 172.18.0.4
172.20.0.0/16 dev eth0 proto kernel scope link src 172.20.0.2
```

Packet capture vantage: `tcpdump -i any` inside `otlab-openplc`. That
vantage sees both `ot_zone` traffic (the attack) and the continuing
`mgmt_zone` FUXA↔OpenPLC baseline (see "What's actually on the wire"
below).

### What's actually on the wire — Phase 1 reality check

The Phase 1 architecture story frames `ot_zone` as the process/Modbus
network. The pre-flight baseline pcap shows the actual FUXA↔OpenPLC
Modbus poll riding **`mgmt_zone` (172.19.0.x)**, not `ot_zone`. Both
services are multi-homed; Docker's embedded DNS resolved `openplc` to
its mgmt_zone IP when FUXA opened its long-lived connection, and that
connection has persisted on mgmt_zone since. The honest scope note in
`docs/network-security.md` §4 ("mgmt_zone↔ot_zone is not a hard
boundary") covers this; the practical implication for Phase 2 work
(esp. Suricata sensor placement in step 3) is tracked separately.

---

## Prediction (stated before running)

- nmap host discovery on `172.18.0.0/24` finds the gateway, openplc,
  fuxa, and the attacker itself.
- TCP port scan finds `openplc:502` (Modbus), `openplc:8080` (OpenPLC
  web), `fuxa:1881` (HMI). Everything else closed.
- Service version detection on 502 will probably not get a clean
  Modbus fingerprint (nmap's Modbus probe is FC-specific and OpenPLC
  may return exception responses), but 8080 and 1881 will disclose
  framework + version info.
- Capture will show the connection-churn pattern that
  `docs/monitoring.md` §5 lists as a suspicious indicator.

---

## Commands

```bash
docker exec -d otlab-openplc-v4 sh -c \
  "tcpdump -i any -U -w /tmp/scenario-1.pcap 'tcp or icmp'"

# 1a. Host discovery
docker exec otlab-attacker nmap -sn 172.18.0.0/24

# 1b. TCP connect scan
docker exec otlab-attacker nmap -sT -Pn \
  -p 22,80,443,502,1881,8080,8443,9001 \
  172.18.0.5 172.18.0.3

# 1c. Service version detection
docker exec otlab-attacker nmap -sV -p 502,1881,8080 \
  172.18.0.5 172.18.0.3

docker exec otlab-openplc-v4 pkill tcpdump
docker cp otlab-openplc-v4:/tmp/scenario-1.pcap \
  ./captures/phase2-scenario-1-recon-2026-05-22.pcap
```

---

## Observed output

### 1a — host discovery

```
Nmap scan report for 172.18.0.1                                  (Docker bridge gateway)
Nmap scan report for otlab-openplc.otlab_ot_zone (172.18.0.2)
Nmap scan report for otlab-fuxa.otlab_ot_zone   (172.18.0.3)
Nmap scan report for 6066784b0201               (172.18.0.4)     (attacker — self)

Nmap done: 256 IP addresses (4 hosts up) scanned in 2.05 seconds
```

Notable: nmap discovered the hosts by their **service-discovery DNS
names** (`otlab-openplc.otlab_ot_zone`, `otlab-fuxa.otlab_ot_zone`).
Once on the bridge, the attacker resolves the same Docker-DNS names the
legit services use. This is the inverse of Phase 2 §1's segmentation
finding — there, the attacker on `attacker_zone` couldn't resolve
`openplc`; here, on `ot_zone`, it can.

### 1b — TCP port scan (predicted-vs-observed)

**openplc (172.18.0.2):**

| Port | State  | Predicted | Observed |
|------|--------|-----------|----------|
| 22   | closed | closed    | closed   |
| 80   | closed | closed    | closed   |
| 443  | closed | closed    | closed   |
| 502  | **open** | open    | open (mbap) |
| 1881 | closed | closed    | closed   |
| 8080 | **open** | open    | open (http-proxy) |
| 8443 | **open** | closed  | **open (https-alt) — UNEXPECTED** |
| 9001 | closed | closed    | closed   |

**fuxa (172.18.0.3):**

| Port | State  | Observed |
|------|--------|----------|
| 1881 | **open** | open (Node.js Express) |
| all others | closed | closed |

### 1c — service version detection (excerpted)

```
PORT     STATE  SERVICE       VERSION
502/tcp  open   mbap?         (unrecognized — nmap's Modbus probe
                               got binary responses but no clean
                               fingerprint; raw bytes look like
                               Modbus exception responses to
                               unsupported function codes)
8080/tcp open   http-proxy    Werkzeug/2.3.7 Python/3.13.5
8443/tcp (not probed in 1c)

fuxa:1881  open  http          Node.js Express framework
```

Information disclosure on 8080:

```
Server: Werkzeug/2.3.7 Python/3.13.5
Set-Cookie: session=eyJfZnJlc2giOmZhbHNlLCJfcGVybWFuZW50Ijp0cnVlfQ...
Location: /login
```

The session-cookie payload decodes to `{"_fresh":false,"_permanent":true}`
— Flask session-cookie format, no secrets in this snapshot, but the
*format* tells the attacker the framework's session model.

### Packet capture summary

- 1171 packets in `captures/phase2-scenario-1-recon-2026-05-22.pcap`
- Distinct destination ports the attacker hit on openplc (extracted
  from the pcap):

```
> 172.18.0.2.22:
> 172.18.0.2.80:
> 172.18.0.2.443:
> 172.18.0.2.502:
> 172.18.0.2.1881:
> 172.18.0.2.8080:
> 172.18.0.2.8443:
> 172.18.0.2.9001:
```

- The connection-churn pattern is unambiguous — every probe is a SYN
  with an immediate RST/RST-ACK close. tcpdump excerpt (3 sample
  probes against closed/open/open ports):

```
18:04:54.522565 IP 172.18.0.4.36276 > 172.18.0.2.80:   Flags [S]   <-- probe
18:04:54.522569 IP 172.18.0.2.80    > 172.18.0.4.36276: Flags [R.]  <-- port closed
18:04:54.522756 IP 172.18.0.4.53788 > 172.18.0.2.8080: Flags [S]   <-- probe
18:04:54.522774 IP 172.18.0.2.8080  > 172.18.0.4.53788: Flags [S.] <-- SYN-ACK = open
18:04:54.523033 IP 172.18.0.4.43958 > 172.18.0.2.502:  Flags [S]
18:04:54.523036 IP 172.18.0.2.502   > 172.18.0.4.43958: Flags [S.] <-- :502 open
```

This matches `docs/monitoring.md` §5 row 5 (*"Connection churn —
many short connections = scan / brute"*) and row 2 (*"New source
IP to :502"*). Both are scheduled to be Suricata rules in step 3.

---

## Finding (plain English)

The attacker, once placed on `ot_zone`, sees the lab the way a
domain-joined laptop on a flat OT network would: every service is
addressable, the Docker DNS names work, and nmap completes the full
recon in roughly two minutes.

The PLC discloses three things to an unauthenticated scanner:

1. **The Modbus service is running** (`502/tcp`). That's by design —
   it has to be, for FUXA to poll it. The point isn't that it's open;
   the point is that nothing protects who reaches it.
2. **The PLC management web UI is exposed on `ot_zone`** (`8080/tcp`,
   Werkzeug/2.3.7 + Python/3.13.5). The HTTP server reveals exact
   framework + interpreter versions in its `Server:` header — an
   attacker now has two CVE-search keywords without sending a single
   payload.
3. **A second port (`8443/tcp`) is listening that is not documented
   in the Phase 1 port table.** Predicted closed, observed open.
   **Identified** (verified after the scenario, 2026-05-22): this is
   the HTTPS variant of the OpenPLC v3 web UI — `python3
   webserver.py` (PID 14, same Flask/Werkzeug process that serves
   :8080) is running with Flask's adhoc SSL context, exposing the
   same management UI over HTTPS on a second port. The matching
   `Server: Werkzeug/2.3.7 Python/3.13.5` header confirms it.
   **Hardening implication.** Phase 3 work that restricts the
   OpenPLC management surface by firewalling :8080 will leave :8443
   wide open because Phase 1's port table only lists :8080. The
   generic pattern — *documented port set ≠ actually-listening port
   set* — is worth a fresh port-scan sanity check at the start of
   any Phase 3 hardening pass. Tracked as a Phase 2 Finding in
   `docs/MASTER.md` §3.

The HMI also discloses:

4. **FUXA is identifiable as Node.js Express** on port 1881 — useful
   recon, same lesson as #2 (frameworks disclose themselves).

**What this means for the security story.** Phase 1's
`docs/network-security.md` §6 row 2 ("On `ot_zone` (already inside) —
full Modbus read/write") is now demonstrated end to end. An attacker
who reaches `ot_zone` does not need to break Modbus to do damage —
they can also reach the PLC's management UI, which still has default
credentials (`openplc / openplc`, per §5.1). The Modbus-no-auth lesson
is one of several; the "ot_zone is a flat, trust-everything segment"
lesson is the bigger one.

**What recon ALONE does not yet show:**

- What Modbus operations the PLC will actually accept (scenario 2).
- Whether a write to a coil/register lands (scenarios 3, 4).
- Whether captured frames can be replayed verbatim (scenario 5).

Those are next.

---

## Cross-references

- `docs/network-security.md` §6 row 2 — "attacker on `ot_zone`" view,
  now empirically demonstrated.
- `docs/monitoring.md` §5 — suspicious indicators triggered: new
  source IP to :502 (#2), connection churn (#5). Out-of-map reads
  (#6) not exercised here; that's scenario 2.
- `captures/phase2-scenario-1-recon-2026-05-22.pcap` (gitignored,
  1171 packets, 126 KB).
