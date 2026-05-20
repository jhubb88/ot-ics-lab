# Monitoring — Capturing Modbus/TCP (Phase 1)

This closes the loop from `docs/network-security.md` §5: Modbus/TCP is
unauthenticated and plaintext. Here we *observe* it, establish a normal
baseline, and define what suspicious looks like. Capture artifacts go in
`captures/` (gitignored — see `.gitignore`).

`README.md` = run it. `architecture.md` = how it fits.
`network-security.md` = why. This = how to watch the wire.

---

## 1. Where the Modbus traffic actually is (read this first)

Honest nuance — getting this wrong is the #1 "I see no Modbus" problem:

| Path | What it is | Where it rides |
|---|---|---|
| FUXA ↔ OpenPLC (the real HMI poll) | Container → container by service name `openplc:502` | The **`ot_zone` Docker bridge**, NOT host loopback |
| Host tool → OpenPLC | Windows/WSL Modbus client to `localhost:502` | The **host-published port** (Docker NAT) |

The published `502` exists for host-side tooling/Wireshark; the legitimate
HMI poll does **not** traverse it. So pick the capture method to match what
you want to see (§3).

---

## 2. Modbus function codes (decoder key)

| FC | Operation | Expected in this lab? |
|---|---|---|
| 1 | Read Coils | **Yes** — FUXA reads pump/valve/alarm |
| 2 | Read Discrete Inputs | No |
| 3 | Read Holding Registers | **Yes** — FUXA reads level + setpoints |
| 4 | Read Input Registers | No |
| 5 | Write Single Coil | **No legitimate writer exists** |
| 6 | Write Single Register | **No legitimate writer exists** |
| 15 | Write Multiple Coils | **No legitimate writer exists** |
| 16 | Write Multiple Registers | **No legitimate writer exists** |

Key fact for the baseline: **Phase 1 has zero legitimate Modbus writes.**
FUXA only polls (reads). Any write (FC 5/6/15/16) is, by definition,
not normal traffic for this lab.

---

## 3. Capture methods

### Method A — Host-side client (beginner, demonstrates the lesson)  *(MANUAL)*

Best for *showing* the "no auth" exposure: you act as an unauthenticated
client against the published port and capture it on Windows.

1. Confirm the PLC is **Running** in OpenPLC (`http://localhost:8080`).
2. Open **Wireshark on Windows**. Capture on the interface carrying
   `localhost`/Docker traffic (the **Adapter for loopback traffic**, or the
   `vEthernet (WSL)` / Docker Desktop adapter — try loopback first).
3. Display filter:
   ```
   modbus || mbtcp
   ```
4. From a Windows/WSL Modbus client (e.g. `mbpoll`, a Python `pymodbus`
   snippet), read Holding Register 0 from `127.0.0.1:502`. You will see the
   request/response in clear text — no credentials anywhere. That *is* the
   security lesson; screenshot it for the portfolio.
5. Optional, to show forgeability: issue a **Write Single Register (FC 6)**
   to a setpoint mirror. It is accepted with no authentication. Stop here —
   this is demonstration, not a destructive exercise.

### Method B — The real HMI↔PLC poll (accurate, container path)  *(MANUAL)*

Best for the *normal baseline* — the actual FUXA polling cadence.

The traffic is on the `ot_zone` bridge, so capture there:

```bash
# Capture the real FUXA->OpenPLC Modbus from inside the PLC container.
docker exec otlab-openplc sh -c \
  "command -v tcpdump || (apt-get update && apt-get install -y tcpdump)"
docker exec otlab-openplc tcpdump -i any -w /tmp/modbus.pcap 'tcp port 502'
# ...let it run while the tank cycles a few times, Ctrl-C, then:
docker cp otlab-openplc:/tmp/modbus.pcap ./captures/modbus.pcap
```

Open `captures/modbus.pcap` in Wireshark, filter `modbus || mbtcp`.
(Installing tcpdump in the container is a runtime convenience; it does not
change the image and is gone on container recreation — acceptable for a
capture session.)

---

## 4. Normal baseline (what healthy looks like)

With FUXA connected and the PLC running, expect:

| Property | Normal value |
|---|---|
| Source → Dest | `fuxa` → `openplc:502` only (one client) |
| Function codes | **FC 3** and **FC 1** only (reads) |
| Registers/coils touched | HR 0/1/2, Coils 0/1/2 — the documented map only |
| Cadence | Steady, periodic polling (FUXA's poll interval) |
| TCP connections | One long-lived connection reused, not churn |
| Exceptions | None (no Modbus exception responses) |

A clean baseline screenshot of repeating FC 3/FC 1 at a steady interval is
the artifact to keep (`docs/img/wireshark-modbus.png`, per README).

---

## 5. Suspicious indicators (what to flag)

Anything that deviates from §4. Specifically:

| Indicator | Wireshark filter | Why it's suspicious |
|---|---|---|
| Any write | `modbus.func_code == 5 \|\| modbus.func_code == 6 \|\| modbus.func_code == 15 \|\| modbus.func_code == 16` | No legitimate writer exists in Phase 1 |
| New source IP to `:502` | `tcp.port == 502 && ip.src != <fuxa ip>` | Only FUXA should talk to the PLC |
| Function-code scanning | `modbus` + sort by func code | Sequential/varied FCs = recon/enumeration |
| Modbus exceptions | `modbus.exception_code` | Probing invalid addresses/functions |
| Connection churn | `tcp.flags.syn == 1 && tcp.port == 502` | Many short connections = scan / brute |
| Reads outside the map | inspect register/coil addresses | Enumerating beyond HR0–2 / Coils 0–2 |

These map directly to the §6 "attacker on `ot_zone`" row of
`docs/network-security.md`. Phase 1 *defines* these indicators; Phase 2's
Suricata + attacker container will *generate and detect* them.

---

## 6. Saving artifacts

- Save captures as `captures/<scenario>-<date>.pcap` (folder is gitignored;
  keep raw pcaps out of the repo).
- Keep only screenshots in `docs/img/` for the portfolio write-up.
- Recommended baseline set: a clean normal-poll capture, plus (Method A) one
  capture showing an unauthenticated read/write succeeding — the before/after
  that makes the "Modbus has no security" point concrete.

---

## 7. Phase 2 hook

`docs/MASTER.md` backlog: Suricata passive monitoring consumes this same
`ot_zone` traffic and the §5 indicator list becomes detection rules; the
attacker container generates the traffic those rules fire on.
