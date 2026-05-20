# OT/ICS Security Lab — MASTER (Status & Index)

Single source of truth for this project's status, decisions, risks, and
document map. Vendor-neutral OT/ICS security lab — a portfolio /
recruiter-facing artifact where the *reasoning* behind each choice is part
of the deliverable, not just the plumbing.

- **Project:** Vendor-neutral OT/ICS security lab (portfolio / recruiter-facing)
- **Process simulated:** Generic plant tank-fill (level, pump, valve, high alarm)
- **Phase:** 1 of 2
- **Phase 1 status:** **Acceptance gate fully met — runtime, visual HMI, and Modbus/TCP capture all proven end-to-end** (see Acceptance Gate)
- **Last updated:** 2026-05-20
- **Repo:** `<repo-root>` (your local clone location; absolute path is environment-specific)

---

## Document Index

| File | Purpose |
|---|---|
| `README.md` | What it is, prerequisites, setup, run, test, screenshots, security talking points |
| `docs/architecture.md` | Components, control + process model, data flow, zones, trust boundaries |
| `docs/network-security.md` | Threat model, supply-chain control, least privilege, segmentation, exposure, attacker view |
| `docs/monitoring.md` | Wireshark Modbus capture (host + container paths), normal baseline vs. suspicious |
| `docs/MASTER.md` | This file — status, locked decisions, risks, Phase 2 backlog |
| `plc/Dockerfile` | OpenPLC v3 built from pinned upstream source (supply-chain rationale in header) |
| `plc/tank_fill.st` | Control logic + process model, IEC 61131-3 Structured Text |
| `docker-compose.yml` | 2 services, 3 networks, FUXA persistence |
| `.gitignore` | Runtime state + captures excluded |

---

## Phase 1 — Deliverable Checklist

- [x] **1. Folder structure** — `plc/ fuxa/appdata/ docs/ captures/`
- [x] **2. Compose stack**
  - [x] 2a `plc/Dockerfile` — OpenPLC v3 built from pinned upstream source
  - [x] 2b `docker-compose.yml` — 2 services, 3 networks, FUXA persistence
  - [x] 2c `.gitignore` — runtime state + captures excluded
- [x] **3. `plc/tank_fill.st`** — OpenPLC tank-fill control logic (Structured Text)
- [x] **4. `README.md`** — what it is, prereqs, setup, run, test, screenshots, talking points
- [x] **5. `docs/architecture.md`** — components, data flow, zones
- [x] **6. `docs/network-security.md`** — segmentation rationale, exposure, attacker view
- [x] **7. `docs/monitoring.md`** — Wireshark Modbus capture, normal vs. suspicious
- [x] **8. `docs/MASTER.md`** — full index + final status (this file; stub replaced)

**All 8 build deliverables are authored.** This is *not* the same as Phase 1
acceptance — see the gate below.

---

## Acceptance Gate (Phase 1 — fully met)

All four Phase 1 acceptance criteria are met:

- [x] `docker compose up --build` brings up `otlab-openplc` + `otlab-fuxa`
- [x] `tank_fill.st` compiles in OpenPLC and the PLC is **Running**
      (clean compile after the MATIEC fix-pass — see Known Risks)
- [x] FUXA connects to `openplc:502` (Slave ID 1, status green) and the tank
      cycles per the hysteresis logic — data path verified via pymodbus from
      a container on `otlab_ot_zone` (HR0 cycled 49→69→71→51→31; HR1/HR2 =
      SP_Low 20 / SP_High 80), and the FUXA HMI (bar gauge bound to Level,
      numeric `%` label, Pump ON/OFF, Valve OPEN/CLOSED, Alarm
      NORMAL/ACTIVE indicators) renders the live cycling — screenshot at
      `docs/img/fuxa-hmi.png` shows tank at 68 % with a manually-triggered
      alarm so all three indicator states are visible in one frame.
- [x] Modbus/TCP packets captured in Wireshark per `docs/monitoring.md` —
      capture taken from inside `otlab-openplc` on the `ot_zone` bridge:
      2502 packets, 0 dropped, steady FC 3 + FC 1 polling pattern from FUXA
      (172.19.0.3) → OpenPLC (172.19.0.2:502), no writes (FC 5/6/15/16 = 0),
      no Modbus exceptions, ~1 s cadence, single long-lived TCP connection.
      Matches `docs/monitoring.md` §4 normal baseline exactly. Capture at
      `captures/modbus-baseline-20260520.pcap` (gitignored); screenshot at
      `docs/img/wireshark-modbus.png`.

**Status:** Phase 1 fully accepted in this environment — OpenPLC built from
pinned source, ST compiled clean, PLC Running, live Modbus/TCP serving correct
cycling data on :502, FUXA HMI animating with all six bound tags (Level HR0,
SP_Low HR1, SP_High HR2, Pump Coil 0, Valve Coil 1, Alarm Coil 2), and the
Modbus/TCP capture confirms the clean normal-poll baseline documented in
`docs/monitoring.md` §4 (reads-only, single client, single long-lived
connection). Ready for public repo flip after remaining closeout items
(see Open Items).

---

## Key Decisions Locked (recruiter-relevant)

| Decision | Choice | Why it matters |
|---|---|---|
| OpenPLC image | Built from pinned upstream commit `b5d4135…` | No unvetted Docker Hub image — supply-chain control is part of the security story |
| FUXA image | `frangoteam/fuxa:1.3.1` (pinned) | No moving `:latest`; reproducible |
| `--privileged` | **Not** set on OpenPLC | Deliberate least-privilege; no hardware I/O in this lab |
| `.env` file | None in Phase 1 | Fewer first-run failure modes for a beginner |
| Zoning | `ot_zone`, `mgmt_zone`, `attacker_zone` (empty) | `attacker_zone` is the genuinely enforced boundary; Phase 2 probes it |

---

## Known Risks / VERIFY-ON-FIRST-RUN

- OpenPLC builds from source on first `docker compose up` (~minutes; unverified
  end-to-end in this environment) — fallback documented in README.
- OpenPLC running without `--privileged` — fallback documented in README.
- FUXA persistence path `/usr/src/app/FUXA/server/_appdata` — confirmed on first run.
- ~~OpenPLC Structured Text program may need a fix pass on first compile~~
  **RESOLVED 2026-05-19.** MATIEC rejected mixing AT-located and non-located
  declarations in one `VAR` block (errors lines 45–54, cascading to 6
  assignments). Fix: split into two homogeneous `VAR…END_VAR` blocks within
  the same `PROGRAM` (located outputs separate from internal state). Clean
  compile, PLC Running.
- **OpenPLC v3 web UI Monitoring page is unreliable** — shows zeros and only
  3 of 6 variables despite correct live Modbus output. Cosmetic UI quirk of
  OpenPLC v3, not a runtime fault. Modbus/TCP (pymodbus / Wireshark) is the
  source of truth. Dashboard status display also caches stale state: after
  Start PLC *and* after `docker compose down`/`up` cycles, it can show the
  wrong run/stop indicator even with Ctrl+F5. Authoritative "is the PLC
  actually running" answer is `docker logs otlab-openplc` or a Modbus read
  against `:502` (e.g., pymodbus reading HR0 — non-zero, cycling values
  prove the PLC is running), never the dashboard.
- FUXA → OpenPLC Modbus host must be the service name `openplc:502`, never
  `localhost` — the #1 first-run failure (fix in README Troubleshooting).

---

## Authoring Discipline (lessons learned)

Doc references must resolve. When any doc in this repo names a file path
(image, log, config, script), that path must either exist on disk at the
time of commit OR be explicitly flagged as MANUAL with a clear "you need
to create this" note. Authoring references to non-existent paths produces
the silent drift the project rules exist to prevent.

- Lesson source: 2026-05-19 MASTER.md update referenced `docs/img/fuxa-hmi.png`
  in two places before the `docs/img/` directory was created — caught and
  fixed same day, but is exactly the class of error this rule blocks.
- Process improvement (future projects): when a `.gitignore` is authored at
  folder creation, `git init` should happen in the same step. Lesson source:
  2026-05-19 — this repo had a Phase-1-anticipating `.gitignore` from day
  one but `git init` only happened on day three, meaning every prior fix
  pass (MATIEC, HMI, MASTER.md updates) shipped without revision history.
- 2026-05-20 — pre-public-flip scan caught two hardcoded absolute paths in
  committed docs (`README.md`, `docs/MASTER.md`), both pointing at the
  author's local WSL2 clone location. Generalized to a `<repo-root>`
  placeholder, defined inline at each site. Process improvement: before
  any first push to a public repo, grep for user-specific paths and known
  sensitive strings as a standard pre-flight.
- 2026-05-20 — Phase 1 compose stack persisted FUXA HMI state but not
  OpenPLC program/runtime state. Asymmetry discovered during a routine
  down/up cycle test. Process improvement: when one service in a stack
  has persistence wired, audit every other service for the same need at
  the same time, not later.

---

## Open Items (Phase 1 follow-ups — not blocking acceptance)

- Additional portfolio screenshots beyond the two already captured
  (`docs/img/fuxa-hmi.png`, `docs/img/wireshark-modbus.png`):
  `docs/img/openplc-running.png` and `docs/img/fuxa-alarm.png` still pending.
- FUXA HMI layout polish — numeric `%` label floats per value width
  (`33%` / `48%` / `68%` shift horizontally), minor alignment between the
  Pump/Valve/Alarm indicator row. Acceptable for Phase 1; track as a
  Phase 2 polish item, non-blocking.
- `architecture.md` §5: add one-sentence note that Compose skips
  materializing `attacker_zone` until a service attaches (confirmed
  2026-05-20 — only `otlab_ot_zone` + `otlab_mgmt_zone` exist on the live
  host). Daemon-level default-deny between bridges keeps the segmentation
  argument intact regardless.

---

## Phase 2 Backlog (documented only — NOT built in Phase 1)

- [ ] Suricata passive monitoring
- [ ] Attacker container in `attacker_zone` (ICS recon/attack tooling)
- [ ] Historian (InfluxDB + Grafana)
- [ ] Written-up attack scenarios
- [ ] Real network diagram with assigned IPs
- [ ] Tighten `mgmt_zone` ↔ `ot_zone` into a hard boundary (currently soft)
- [ ] Evaluate migration OpenPLC v3 → v4 (v3 is upstream EOL)

---

## Environment Prerequisite (MANUAL)

- Docker Desktop on Windows with **WSL2 integration enabled** for this distro.
  *(Status 2026-05-19: Docker Desktop installed, WSL2 integration confirmed.
  Lab proven running end-to-end — `docker compose up --build` built OpenPLC
  from pinned source, ST compiled clean, PLC Running, live Modbus/TCP on :502
  verified via pymodbus, FUXA connected. Visual HMI + Wireshark pending —
  see Acceptance Gate.)*
