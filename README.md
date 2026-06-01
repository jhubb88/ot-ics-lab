# OT/ICS Security Lab — Tank-Fill Process

A self-contained, vendor-neutral **Operational Technology (OT) / Industrial Control
Systems (ICS) security lab**, built entirely in Docker. It runs a realistic
**PLC + HMI** control loop for a simulated plant tank-fill process, on a
**segmented three-zone network**, with **passive IDS detection** and a **time-series
historian** wired in.

The lab demonstrates a full defensive OT stack end to end — process control,
operator visualization, network segmentation, intrusion detection, and historian/
dashboards — and uses it as a platform to run and document realistic Modbus/TCP
attack scenarios against a PLC. Every version is pinned and every architectural
choice is recorded as an ADR or a numbered finding.

> **Scope:** a personal learning / portfolio lab (Docker Desktop + WSL2). Not a
> production system and not original security research — it applies well-understood
> ICS-security concepts to a working, reproducible stack.

---

## Architecture

Seven containers across three isolated Docker networks. All images are version-pinned.

| Component | Role | Image (pinned) |
|---|---|---|
| **OpenPLC Runtime v4** | PLC — runs IEC 61131-3 control logic, serves Modbus/TCP | `ghcr.io/autonomy-logic/openplc-runtime:v4.0.9` |
| **FUXA** | HMI — the operator screen (tank, pump, valve, alarm) | `frangoteam/fuxa:1.3.1` |
| **Suricata** | Passive IDS sensor (alert-only) | `jasonish/suricata:8.0.5` |
| **Telegraf** | Collector — polls the PLC over Modbus, writes to InfluxDB | `telegraf:1.38.4-alpine` |
| **InfluxDB** | Historian — time-series store for PLC metrics | `influxdb:2.9.1` |
| **Grafana** | Dashboards over the historian | `grafana/grafana:13.0.1-security-01` |
| **Attacker** | Recon / Modbus toolbox; models an internal foothold | built from `./attacker` (pinned Debian) |

### Network zones

```
┌─ mgmt_zone  172.19.0.0/16 — engineering / browser access ──────────────┐
│   Grafana :3000     InfluxDB :8086     FUXA HMI :1881                   │
└────────────────────────────────┬───────────────────────────────────────┘
        (FUXA, Telegraf, Suricata are multi-homed across both zones)
┌─ ot_zone   172.18.0.0/16 — plant floor / Modbus/TCP ───────────────────┐
│   FUXA ──Modbus :502──▶ OpenPLC v4 (PLC) ◀──Modbus── Telegraf           │
│   Suricata  — passive IDS, sees the process network                     │
└───────────────────────────────────────────────────────▲────────────────┘
                                                         ┊ scenarios attach
                                                         ┊ the attacker here
┌─ attacker_zone  172.20.0.0/16 — the attacker's starting point ─────────┐
│   Attacker toolbox                                                      │
│     default:    isolated  ✕──  no route to ot_zone  (segmentation proof)│
│     scenarios:  docker network connect  ┄┄▶ ot_zone (internal foothold) │
└─────────────────────────────────────────────────────────────────────────┘

Historian data path:  OpenPLC ──Modbus──▶ Telegraf ──▶ InfluxDB ──▶ Grafana
```

The attacker container is **isolated by default** — placed only on `attacker_zone`, it
has no route to the PLC, which is the lab's baseline segmentation proof. Each attack
scenario then **deliberately** attaches it to `ot_zone` (`docker network connect`, step 2
of every scenario) to model an adversary who has *already* gained an internal foothold —
the realistic ICS threat. Both states are the point: the default shows the boundary
holds; the scenarios show what an attacker can do once inside.

(Honest scope note: for usability the two legitimate services are multi-homed on both
production zones, so the `mgmt_zone ↔ ot_zone` split is soft today; hardening it into a
strict boundary is tracked backlog. Full rationale in `docs/network-security.md`.)

The PLC program (`plc/tank_fill.st`, IEC 61131-3 Structured Text) **simulates its own
plant** — there is no hardware. The tank fills when the pump and valve are active and
drains continuously, cycling on hysteresis (fill → stop at the high setpoint → drain →
restart at the low setpoint), with a high-high level alarm.

---

## Run it

Prerequisites: Docker Desktop with WSL2 integration. An `.env` supplying the InfluxDB
and Grafana init credentials is required (consumed by `docker-compose.yml`; `.env` is
gitignored).

```bash
docker compose up -d          # brings up all 7 containers
docker compose ps             # FUXA shows (healthy) once its Modbus poll is established
```

From the Windows browser: **FUXA HMI** `http://localhost:1881` · **Grafana**
`http://localhost:3000` · **InfluxDB** `http://localhost:8086`. (OpenPLC v4 exposes a
JWT-auth REST API on `:8443`, not a web UI — it is driven by the OpenPLC Editor v4
desktop app.) Day-to-day operation is documented in `docs/runbooks/lab-operations.md`.

---

## What's built

- **PLC simulation** — OpenPLC v4 running a tank-fill control loop over Modbus/TCP,
  with the process model simulated in the PLC program itself.
- **HMI** — FUXA operator screen bound to the PLC's live tank level, pump, valve, and
  alarm.
- **Network segmentation** — three pinned-subnet Docker zones with an isolated
  `attacker_zone` as the enforced default boundary.
- **Intrusion detection** — Suricata with a **13-rule Modbus/recon ruleset** (SIDs
  `9000001–9000021`): 5 recon rules (host-discovery / port-scan / SYN-to-PLC), 6
  Modbus protocol rules (writes from non-HMI sources, out-of-map reads, unused function
  codes), and 2 non-HMI Modbus-read rules. Alert-only IDS; detection is verified by
  **offline pcap replay** through Suricata.
- **Historian + dashboards** — Telegraf → InfluxDB → Grafana, collecting PLC registers
  (tank level, setpoints, coil states) on a 3-second cadence.
- **Documented attack scenarios** — five Modbus/TCP scenarios (recon → function-code
  scan → coil write → register write → replay), each captured to a pcap and replayed
  through the IDS, in `docs/phase2/scenarios/`.

---

## Findings highlight

The lab produces real, reproducible results — not just infrastructure. The strongest
example: live-fire testing showed that **OpenPLC v4 reasserts program-driven outputs on
every scan cycle** — the coils and registers the PLC program rewrites each scan (the
alarm coil, the setpoint mirrors) — so an external Modbus write to one of *those*
outputs is *detected on the wire but never persists*: the runtime overwrites it within
~100 ms (read-back stuck 0/40 in testing). This is a genuine v3→v4 behavioral difference
(v3 let such writes linger between scans) and is written up as findings **§30 / §31** in
`docs/MASTER.md`. It is a scoped result — it does not mean v4 blocks all writes; targets
the program does *not* reassert remain the open case. The same document records the
offline-replay detection methodology and the full Suricata SID baseline, and the
architectural decisions are captured as ADRs in `docs/decisions/` (the v3→v4 migration
and the historian-stack selection).

---

## Repository layout

```
docker-compose.yml        7 services, 3 networks, pinned images + IPs
plc/                      OpenPLC control logic (tank_fill.st) + v4 plugin config
fuxa/                     HMI project data (persisted)
suricata/                 suricata.yaml + rules/local.rules (13 SIDs) + logs
telegraf/                 Modbus-input → InfluxDB-output collector config
grafana/                  datasource + dashboard provisioning
captures/                 pcaps (gitignored)
docs/
  MASTER.md               status, locked decisions, numbered findings
  architecture.md         components, process/control model, zones
  network-security.md     threat model, segmentation, attacker view
  monitoring.md           Modbus capture + baseline-vs-suspicious traffic
  decisions/              ADRs (0001 v3→v4 stack, 0002 historian stack)
  phase2/                 detection write-ups + attack scenarios
  runbooks/               lab-operations.md (daily operation)
```

---

## Status & scope

A personal learning / portfolio project, run on Docker Desktop + WSL2.

**Built and working:** PLC + HMI control loop; three-zone segmentation with an isolated
attacker; Suricata IDS (13 rules) with offline-replay verification; the five documented
attack scenarios; the Telegraf/InfluxDB/Grafana historian; the OpenPLC v3→v4 migration.

**Backlog (see `docs/MASTER.md`):** hardening the soft `mgmt_zone ↔ ot_zone` boundary
into a strict one, and live IDS capture (currently offline-replay only — Docker Desktop
host networking is layer-4-only, so live AF_PACKET capture needs Docker Engine on Linux).

---

## License

MIT — see `LICENSE`.
