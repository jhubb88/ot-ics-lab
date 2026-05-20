# Architecture — OT/ICS Security Lab (Phase 1)

How the pieces fit, how data moves, and why the trust boundaries are drawn
where they are. Setup/run lives in `README.md`; build status in
`docs/MASTER.md`. This document is the *design rationale*.

---

## 1. System overview

Two containers model the two halves of a real control system:

| Container | Role | Real-world equivalent |
|---|---|---|
| `otlab-openplc` | PLC — runs control logic, serves Modbus/TCP | The PLC in a plant cabinet |
| `otlab-fuxa` | HMI — reads Modbus, renders the operator screen | The SCADA/HMI panel an operator watches |

There is **no physical I/O**. The PLC program is both the *controller* and
the *process model* (see §3) — a deliberate choice that keeps the lab
hardware-free and `--privileged`-free without losing realistic Modbus
traffic. The security rationale for this is in `docs/network-security.md`.

```
            mgmt_zone (human / browser)
        ┌───────────────┬───────────────────┐
        │               │                   │
   :8080 OpenPLC     :1881 FUXA              │  ← Windows browser
     web editor        HMI UI                │     via localhost
        │               │                   │
========│===============│=================== │ ====================
        │           ot_zone (process)        │
        │               │                   │
   ┌────┴─────┐  Modbus/TCP :502   ┌─────────┴────┐
   │ OpenPLC  │ ◀───────────────── │     FUXA     │
   │  (PLC)   │ ─────────────────▶ │    (HMI)     │
   └──────────┘   level/pump/      └──────────────┘
                  valve/alarm

   attacker_zone : defined, EMPTY in Phase 1 (no route to ot_zone)
```

---

## 2. Components

### 2.1 OpenPLC v3 (the PLC)

- Built from **pinned upstream source** (`plc/Dockerfile`), not a Docker Hub
  image — supply-chain control (full rationale in the Dockerfile header and
  `docs/network-security.md`).
- Runs `plc/tank_fill.st` (IEC 61131-3 Structured Text) on a fixed scan task.
- Exposes two distinct surfaces:
  - **:8080** — web editor / management UI (human, `mgmt_zone`).
  - **:502** — Modbus/TCP server (machine, `ot_zone`).

### 2.2 FUXA (the HMI)

- Pinned image `frangoteam/fuxa:1.3.1`.
- Modbus/TCP **client** — polls the PLC and animates tank/pump/valve/alarm.
- Project state persists to `./fuxa/appdata` (bind mount) so the screen
  survives container recreation.
- Surface: **:1881** — HMI UI (human, `mgmt_zone`).

---

## 3. Control + process model (one program, two jobs)

`plc/tank_fill.st` executes every scan (100 ms task):

1. **Control logic** — hysteresis fill control:
   - Level ≤ 20 % → latch fill ON (pump + inlet valve).
   - Level ≥ 80 % → latch fill OFF.
   - The dead band between setpoints prevents pump short-cycling
     (real-plant practice).
   - Level ≥ 90 % → high-high alarm.
2. **Process model** — integrates the simulated tank:
   - Filling adds inflow per scan; a constant consumption drains every
     scan, so the level continuously cycles.
   - Clamped to a physical 0–100 % range.
3. **Publish** — writes level + setpoints + statuses to the
   Modbus-mapped registers FUXA reads.

```
   Level ≤ 20 ──▶ FILL ──▶ level rises ──▶ Level ≥ 80 ──▶ STOP
        ▲                                                   │
        └──────────────── level drains ◀───────────────────┘
                     (alarm if level ≥ 90)
```

---

## 4. Data flow

```
 OpenPLC scan (100 ms)            FUXA poll (its own interval)
 ─────────────────────            ───────────────────────────
 read internal state              Modbus TCP connect → openplc:502
   → run control logic            read Holding Reg 0  (level)
   → step process model           read Holding Reg 1/2 (setpoints)
   → write %QW / %QX              read Coils 0/1/2     (pump/valve/alarm)
   → Modbus server updates  ───▶  render screen, repeat
```

The two loops are **independent and asynchronous**. The PLC does not push;
FUXA polls. This is exactly how real PLC↔SCADA Modbus works, and is why the
traffic is steady and capturable (`docs/monitoring.md`).

### Modbus map (authoritative copy in `plc/tank_fill.st`)

| Tag | ST address | Modbus object | Address |
|---|---|---|---|
| Tank level (0–100 %) | `%QW0` | Holding Register | 0 |
| Low setpoint (display) | `%QW1` | Holding Register | 1 |
| High setpoint (display) | `%QW2` | Holding Register | 2 |
| Pump running | `%QX0.0` | Coil | 0 |
| Valve open | `%QX0.1` | Coil | 1 |
| High-high alarm | `%QX0.2` | Coil | 2 |

---

## 5. Network zones

Three Docker bridge networks model plant segmentation:

| Zone | Docker name | Purpose | Members (Phase 1) |
|---|---|---|---|
| `ot_zone` | `otlab_ot_zone` | Process network — Modbus/TCP PLC↔HMI | openplc, fuxa |
| `mgmt_zone` | `otlab_mgmt_zone` | Engineering — human web access to UIs | openplc, fuxa |
| `attacker_zone` | `otlab_attacker_zone` | Adversary segment | **none (empty)** |

**Honest scope note.** In Phase 1 both legitimate services are multi-homed
on `ot_zone` + `mgmt_zone` for usability, so those two are not a hard
boundary between each other here. The **genuinely enforced** boundary is
`attacker_zone`: Docker bridge networks are isolated from each other by
default, so a container placed *only* in `attacker_zone` has no route to
`ot_zone`. That is the boundary Phase 2's attacker container will probe.
Threat-model detail and the segmentation argument live in
`docs/network-security.md`; this document just states where the lines are.

---

## 6. Trust boundaries (summary)

| Boundary | Phase 1 status | Notes |
|---|---|---|
| Windows host ↔ containers | Published ports only (`8080`, `1881`, `502`) | `502` published only for Wireshark / host Modbus tooling |
| `mgmt_zone` (human) ↔ `ot_zone` (process) | Soft — services multi-homed | Tightened conceptually in `network-security.md`; not hardened in Phase 1 |
| `attacker_zone` ↔ `ot_zone` | **Hard — no route** | The real, demonstrable enforcement boundary |
| PLC ↔ HMI (Modbus) | **None** — Modbus is unauthenticated by design | The core OT lesson; see `docs/monitoring.md` |

---

## 7. What Phase 2 adds (backlog — not built here)

Tracked in `docs/MASTER.md`. Architectural hooks already in place:
`attacker_zone` exists so an attacker container can be dropped in without
touching the rest of the stack; capture workflow (`docs/monitoring.md`)
already documents normal vs. suspicious Modbus so anomalies have a baseline.
