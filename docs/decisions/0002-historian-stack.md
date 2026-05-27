# ADR 0002 — Historian, visualization, and collector stack

**Date:** 2026-05-27
**Status:** Accepted
**Scope:** Architectural decision for the lab's historian, visualization, and PLC-to-historian collector roles entering Queue Item 1 (post-Phase-3)
**Triggering rule:** Tool-selection gate codified in `~/.claude/CLAUDE.md` (≥3 candidates per role, current-version verification, deprecation-status check)
**Empirical work:** Image-pin verification (InfluxDB v2.9.1, Grafana 13.0.1-security-01, Telegraf 1.38.4-alpine) performed live against vendor docs + GitHub releases + Docker Hub on 2026-05-27. Stack candidates evaluated against the parallel research doc preserved at `C:\Users\jimmy\temp\historian-research-cc.md` plus a second independent research pass.

---

## Plain-English summary

The lab gets a **historian** — a database that quietly records every sensor reading from the PLC and stores it for as long as you need. Real plants run historians at "Purdue Level 3," the layer where the plant talks to the office. Three new Docker containers join the lab:

- **InfluxDB** — the historian itself
- **Telegraf** — the "collector" that reads the PLC over Modbus and writes to InfluxDB
- **Grafana** — the dashboard that draws charts of the data

The decision pins specific, older versions on purpose:

- InfluxDB **2.9.1** (the latest of the v2 line; not v3, which is brand new)
- Grafana **13.0.1-security-01**
- Telegraf **1.38.4-alpine**

A specific reason for the pinning: today, 2026-05-27, is the day the Docker Hub `latest` tag for InfluxDB stops pointing at v2 and starts pointing at v3 Core. Any compose file that says `image: influxdb:latest` will silently get a different product with a different storage engine tomorrow. Pinning `2.9.1` is what protects this lab from that flip.

This ADR commits only to the stack and the network plan. It does not write any compose files, pull any images, or build anything. The build is Queue Item 1's actual implementation step, gated behind this ADR.

---

## Context

### What problem this solves

The lab has a PLC (OpenPLC v4.0.9, running a tank-fill control loop) and an HMI (FUXA 1.3.1, the operator screen). It does not have a **historian** — a long-term record of what the PLC was doing.

A historian is to a plant what a flight data recorder is to an airplane. The plane has instruments that tell the pilot what's happening right now. The flight recorder writes everything down so investigators can replay the flight later. A historian does the same job for an industrial process: it stores every sensor reading, every motor state, every alarm, second by second, so engineers can replay any moment of plant operation later.

Real plants run historians for two reasons:

1. **Reports.** Operators, plant managers, and regulators all want to see "how was the plant running last week, last month, last year?" The HMI does not store data long enough to answer that.
2. **Investigations.** When something breaks, you need to be able to ask "what was the chlorine dose at 3:14 AM on Tuesday when the pH spiked?" Only a historian remembers that long.

This lab does not need a historian to run the tank-fill simulation. But every real OT environment has one. Adding one makes the lab look like the real architecture GICSP candidates must understand. It also adds a Purdue Level 3 component the lab currently lacks — until now the stack has been Level 1 (PLC) and Level 2 (HMI) only.

### Why now

Phase 3 closed clean on 2026-05-26 (commit `8343b9d`). Migration from OpenPLC v3 to v4.0.9 is done; 13 Suricata SIDs are loaded and validated; the runbook at `docs/runbooks/lab-operations.md` is current. The stack is stable enough to extend without churn risk.

This is Queue Item 1 — the first post-Phase-3 expansion. The ADR is the gate; the build is the next prompt.

---

## Decision

### Pinned images

| Role | Image pin | Source verification |
|---|---|---|
| Historian | `influxdb:2.9.1` | `gh release list influxdata/influxdb` shows `v2.9.1` as the most recent v2.x release (2026-05-12); `https://docs.influxdata.com/influxdb/v2/install/` references `influxdb2-2.9.1_linux_amd64.tar.gz` in download links |
| Visualization | `grafana/grafana:13.0.1-security-01` | `gh release list grafana/grafana` shows `13.0.1+security-01` as Latest (2026-05-12); Docker Hub tag uses dash form (`13.0.1-security-01`) |
| Collector | `telegraf:1.38.4-alpine` | `gh release list influxdata/telegraf` shows `v1.38.4` as Latest (2026-05-11); Docker Hub confirms `1.38.4-alpine` variant available |

**The `latest` tag flip — load-bearing reminder.** Today, **2026-05-27**, is the day the Docker Hub `latest` tag for `influxdb` flips from v2 to v3 Core. Any compose file pulling `image: influxdb:latest` from today onward gets v3 Core — a different product with a different storage engine (Apache Arrow + Parquet), no Flux query language, and a 72-hour default single-query range cap. The `:2.9.1` pin is what protects against this. The pin is not stylistic; it is functional.

### Data path

```
                ┌──────────────────────────────────┐
                │  ot_zone (existing)              │
                │                                  │
                │  OpenPLC v4.0.9                  │
                │  (Modbus TCP :502)               │
                │            │                     │
                └────────────┼─────────────────────┘
                             │ Modbus reads (1 Hz baseline)
                             ▼
                ┌──────────────────────────────────┐
                │  Telegraf 1.38.4-alpine          │
                │  inputs.modbus  →                │
                │  outputs.influxdb_v2             │
                │  (multi-homed: ot_zone +         │
                │   mgmt_zone)                     │
                └────────────┬─────────────────────┘
                             │ HTTP line protocol
                             ▼
                ┌──────────────────────────────────┐
                │  mgmt_zone (existing)            │
                │                                  │
                │  InfluxDB 2.9.1   (:8086)        │
                │            │                     │
                │            │ InfluxQL / Flux     │
                │            ▼                     │
                │  Grafana 13.0.1   (:3000)        │
                │                                  │
                └──────────────────────────────────┘
```

### Network plan

Three Docker networks already exist: `ot_zone`, `mgmt_zone`, `attacker_zone`.

- **Telegraf is multi-homed.** It joins `ot_zone` (to reach OpenPLC's Modbus port :502) AND `mgmt_zone` (to write to InfluxDB on :8086).
- **InfluxDB and Grafana sit on `mgmt_zone` only.** They never touch `ot_zone`.

This mirrors the real-world IT/OT bridge pattern: the collector is the only component with feet in both worlds. In a production plant, this is the very component that makes historians a high-value attack pivot (see Background Context below). Making the lab's collector deliberately dual-homed reflects that pattern; it does not introduce risk to the live lab because both networks are already Docker bridges on the same host.

`attacker_zone` is unchanged. The attacker container has no path to InfluxDB or Grafana through Docker's default bridge isolation; reaching either would require explicit cross-zone routing, a separate Phase 4+ decision.

---

## Candidates considered

### Historian role

Eight candidates evaluated against the lab's stated purpose (security learning + portfolio + GICSP-adjacent). Full per-candidate detail in the parallel research doc at `C:\Users\jimmy\temp\historian-research-cc.md`. Compressed matrix:

| Candidate | License | Lab footprint | Modbus path | Verdict |
|---|---|---|---|---|
| **InfluxDB v2.9.1** | MIT | ~500 MB RAM | Telegraf (native plugin) | **CHOSEN** |
| InfluxDB v3 Core | MIT or Apache 2.0 | 1–2 GB est. | Telegraf | Rejected — too new, Docker tag flip risk, see Rejected Alternatives |
| TimescaleDB | Apache + TSL split | 256–512 MB | Telegraf (PG output) | Runner-up — see Rejected Alternatives |
| QuestDB | Apache 2.0 | 1–2 GB | Telegraf (ILP) | Rejected — smaller OT community |
| Prometheus | Apache 2.0 | <500 MB | Modbus exporter + scrape | Rejected — pull model, wrong tool for historian role |
| Plain PostgreSQL | PostgreSQL License | 150–300 MB | Telegraf | Rejected — no time-series indexing |
| Ignition Maker Edition | Free (non-commercial) | Heavy (JVM) | Native vendor driver | Rejected for fit, not quality — see Rejected Alternatives |
| VictoriaMetrics, ClickHouse | Apache 2.0 | varies | Telegraf | Considered in research; not pursued for Queue Item 1 |

### Visualization role

Grafana is the de-facto choice for time-series operational dashboards. No alternative is genuinely a peer for THIS lab's source mix:

| Candidate | License | Verdict |
|---|---|---|
| **Grafana 13.0.1-security-01** | AGPLv3 | **CHOSEN** — native InfluxDB v2 datasource, largest OT/ICS tutorial surface, official Docker image |
| Chronograf | AGPLv3 | Rejected — InfluxDB 1.x/2.x admin UI only; InfluxData docs steer v3 users to Grafana |
| Apache Superset | Apache 2.0 | Rejected — SQL/BI tool, not time-series operational dashboard |
| Metabase OSS | AGPLv3 | Rejected — no first-party InfluxDB driver (open FR #13174); BI not time-series |
| Redash | BSD-2-Clause | Rejected — last stable release 2021-11-24; low velocity is a yellow flag for security lab use |

### Collector role

| Candidate | Verdict |
|---|---|
| **Telegraf 1.38.4-alpine** | **CHOSEN** — native `inputs.modbus` plugin paired with native `outputs.influxdb_v2`; zero glue code |
| Node-RED + `node-red-contrib-modbus` | Rejected — flow authoring becomes a third configuration surface; reconnect behavior pushed onto flow authors per `node-red-contrib-modbus` 5.x error-event model |
| Custom Python + `pymodbus` | Rejected — maximally flexible, maximally code-to-maintain; no built-in retry/buffer semantics; trivial to write, non-trivial to operate |
| Apache NiFi | Rejected — JVM footprint plus `GetModbusTCP` is a non-core contributed processor; overkill for a 100-tag lab load |

Telegraf wins on built-in plugin pairing: the Modbus input and the InfluxDB v2 output are both first-party, both currently maintained, and pre-wired in the same daemon. No alternative offers the same "set URL + token + register map → done" handshake.

---

## Why this stack — grounded in research findings

1. **Telegraf-native to InfluxDB.** `inputs.modbus` + `outputs.influxdb_v2` is a zero-configuration handshake (set URL, token, org, bucket — done). No SQL schema design, no custom code, no glue. For an ITS engineer learning OT, this minimizes "fighting integration plumbing instead of learning ICS concepts."
2. **Largest OT-tutorial surface.** Telegraf + InfluxDB + Grafana is the dominant DIY OT-monitoring recipe in the home-lab and integrator community. Tutorial coverage, community Q&A, and example configs are deeper here than for any alternative.
3. **Stable pins, no surprise breaks.** InfluxDB v2 is in maintenance mode but is not EOL. v2.9.1 shipped 2026-05-12 — current and patched, not stale. Telegraf 1.38.4 is the latest stable. All three pins are recent enough to carry current CVE patches.
4. **Pinning avoids the May 27 latest-tag flip.** Discussed in Decision; load-bearing.
5. **Resource footprint fits Docker Desktop on Windows + WSL2.** Three new containers add ~1.5 GB RAM combined. The lab already runs 4 containers comfortably; this roughly doubles the container count, not the memory pressure.

---

## Background context — why historians matter in OT security

*This section is background. It is not a justification for this specific build. The lab is adding the historian for architectural realism, not to stage any specific demo. A future attack scenario may use the historian; today's build is just making it available.*

### Where historians sit in the Purdue model

The Purdue Reference Architecture is the standard layered diagram for OT networks. From bottom to top:

- **Level 0** — field devices: sensors, valves, motors
- **Level 1** — the PLCs and controllers that read the sensors and run the control logic (this lab's OpenPLC v4 lives here)
- **Level 2** — the local control room: HMIs, SCADA, engineering workstations (this lab's FUXA lives here)
- **Level 3** — site operations: plant-wide systems like MES, batch records, and **historians**
- **Level 4** — corporate IT

Historians sit at **Level 3** because they aggregate data from every Level 2 system in the plant and feed reports up to Level 4. (Sources: Palo Alto Networks, Zscaler, Checkpoint, IT/OT Insider — all consistent on Level 3 placement.) The lab has had Levels 1 and 2 since Phase 1; adding the historian gives it a Level 3 component for the first time.

### Why historians become attack pivots

A historian is **dual-homed by design** — it needs to read process data on the OT side (Levels 1–2) and write reports up to the IT side (Level 4). That dual presence makes it the canonical IT↔OT bridge. Attackers know this; several public incidents specifically used historians as the pivot from corporate IT into plant control:

- **TRITON / TRISIS (2017, Saudi petrochemical).** The U.S. Department of Justice indictment of TsNIIKhM operative GLADKIKH explicitly names a historian server ("MACHINE 1") as the entry point used with stolen administrator credentials to reach the engineering workstation connected to the Triconex safety system. The historian was, literally, the pivot.
- **Volt Typhoon (2024, CISA AA24-038A).** PRC state-aligned actor pre-positioned in IT networks of U.S. energy, water, transportation, and communications sectors with stated intent of lateral movement to OT. The advisory implies the IT↔OT bridges (which historians canonically are) without naming a specific pivot product.
- **Claroty Team82's "Hacking ICS Historians: The Pivot Point."** Vendor research framing historians as the most attractive IT→OT pivot. Claroty's own disclosure of the GE Proficy Historian authentication-bypass chain (CVE-2022-46732 + CVE-2022-46660) was a concrete instance.

### What MITRE catalogs

MITRE's ATT&CK for ICS framework treats "Data Historian" as a primary asset class: [Asset A0006](https://attack.mitre.org/assets/A0006/) maps to 49 techniques. The headline technique is [T0810 — Data Historian Compromise](https://attack.mitre.org/techniques/T0810/) — "adversaries may compromise and gain control of a data historian to gain a foothold into the control system environment." Dual-homed historians are called out explicitly as the IT↔OT bridge.

---

## What this enables for future work

Capabilities made available by this build. **Listed as available, not promised.** No commitment to execute any of these on any specific timeline.

- **Custom Suricata rules against IT/OT bridge traffic.** Telegraf being deliberately multi-homed on `ot_zone` and `mgmt_zone` produces the bridge traffic pattern that real-world IDS deployments would alarm on. A future Phase 4 step could write rules targeting cross-zone Modbus + HTTP correlations.
- **Attack scenarios that use the historian.** Examples that *could* be staged later: manipulating historian data to hide an ongoing PLC attack from the operator (a TRITON-style cover-up); enumerating tokens against the InfluxDB authorization API; exploiting a Grafana authz bypass to reach data the attacker should not see.
- **Concrete CVE targets** for those scenarios, if and when they get written:
  - [CVE-2024-30896](https://nvd.nist.gov/vuln/detail/CVE-2024-30896) — InfluxDB OSS 2.x token enumeration via `/api/v2/authorizations`. The lab's pinned 2.9.1 is patched; the *signature pattern* still makes for a teachable detection target.
  - [CVE-2025-3260](https://grafana.com/security/security-advisories/cve-2025-3260/) — Grafana dashboard API authz bypass.
  - [CVE-2025-3454](https://grafana.com/security/security-advisories/cve-2025-3454/) — Grafana datasource proxy authz bypass via trailing slash.
  - [CVE-2024-1313](https://grafana.com/security/security-advisories/cve-2024-1313/) — Grafana snapshot authz bypass.
  - [CVE-2025-6023](https://blog.ethiack.com/blog/grafana-cve-2025-6023-bypass-a-technical-deep-dive) — Grafana open-redirect-to-XSS account takeover.

These are **available targets**, not **planned work**. The Queue Item 1 build delivers only the stack and connectivity; rules and scenarios are out of scope for this ADR.

---

## Risks accepted

### Strategic risks

- **InfluxDB v2 is in maintenance mode.** Not EOL — the project still ships patches (v2.9.1 released 2026-05-12). But InfluxData now steers new deployments to v3 Core. On a 2-to-3-year horizon, expect a v2 sunset announcement. **Mitigation:** keep the historian role loosely coupled — Telegraf output is one config line; Grafana datasource is one panel setting. Future migration to v3 (different storage engine, no Flux, SQL-first) or to TimescaleDB is a deliberate **Phase 4+ decision**, not a problem to solve today.
- **Telegraf as a separate container = more compose surface.** Three new containers instead of two. Documented runbook lift increases proportionally. The Queue Item 3 runbook update absorbs this.

### Operational gotchas (full detail goes in Queue Item 3 runbook)

Flagged here so the ADR captures them at decision time; the runbook will turn each into a concrete operator procedure.

1. **Telegraf timestamps using its own host clock, not the PLC's.** The Modbus protocol carries no timestamp — registers are just bytes on the wire. Telegraf stamps each metric at the moment of poll, using the Telegraf container's host clock. If the host clock drifts, every metric drifts. NTP health on the Docker Desktop host matters.
2. **Telegraf's metric buffer is memory-only.** When InfluxDB is unreachable, Telegraf queues metrics in RAM up to `metric_buffer_limit`. **Restarting Telegraf during an InfluxDB outage loses every queued metric.** A long outage past `buffer / sample_rate` seconds also loses data on the trailing edge.
3. **Silent Modbus decode mismatches.** If the Modbus register layout in `telegraf.conf` does not match how OpenPLC packs the value (byte order ABCD vs CDAB, signed vs unsigned, INT16 vs UINT16), Telegraf writes wrong numbers without raising an error. Validate every newly-added tag against a known-good Modbus client (`mbpoll`, or the FUXA HMI's own poll behavior) before trusting the data.

---

## Rejected alternatives

### InfluxDB v3 Core

InfluxData's actively-developed direction of travel. Dual-licensed MIT or Apache 2.0, modern Apache Arrow + Parquet storage engine, SQL-first via Flight SQL. **Why not chosen:** the v3 storage engine is brand-new (v3.0.0 went GA in April 2025, v3.9.0 the latest feature release on 2026-04-03), tutorial coverage is thinner than v2 by a wide margin, the OSS Core variant has a **72-hour default single-query range cap** (raised by config option, lifted entirely only in Enterprise), and there is no Flux — every v2 example in the wild does not directly translate. The Docker `latest`-tag flip on 2026-05-27 is itself a foot-gun specific to v3: a wrong-tag deploy silently lands on v3 Core. The QuestDB-published v3 Core benchmark also noted heavier RAM use at idle and during compaction than v2. For a lab whose user is new to ICS, choosing v3 stacks "learn ICS" + "learn a brand-new storage engine" + "learn SQL-instead-of-Flux migration" all at once. v2 is the lower-risk learning surface today; v3 is the right migration target for Phase 4+.

### TimescaleDB (runner-up)

Strong alternative, healthier upstream than InfluxDB v2 in absolute terms. Apache 2.0 core (with TSL-licensed advanced features), Postgres-backed (smaller footprint at ~256–512 MB RAM), active release cadence (v2.27.1 released 2026-05-19). **Why not chosen:** thinner OT-specific tutorial coverage. Telegraf + InfluxDB recipes dominate the DIY OT-monitoring community by a wide margin; Timescale recipes for ICS-shaped data exist but are thinner. TimescaleDB is the right choice if the lab later prioritizes license-line purity over tutorial depth; today it loses on tutorial depth.

### QuestDB

Apache 2.0, very active upstream, speaks InfluxDB line protocol so Telegraf works unchanged. **Why not chosen:** smaller OT-specific community, less tutorial coverage, and the heaviest published baseline footprint (vendor docs recommend 4 GB+ RAM for "production"; even a lab load wants 1–2 GB). No specific feature win over v2 for this lab's purpose.

### Prometheus

The pull model is fundamentally a poor fit for the historian role. Prometheus scrapes HTTP `/metrics` endpoints; a Modbus PLC has no such endpoint. Reaching Prometheus requires a separate Modbus exporter (e.g., `RichiH/modbus_exporter`) as a moving part Telegraf does not need. Prometheus also keeps only ~3 hours hot in RAM by default and is architecturally a monitoring system, not an archive — the standard remediation for long-term storage is to remote-write into VictoriaMetrics or Thanos, adding another piece of infrastructure for one historian's worth of retention. Wrong tool for the role.

### Plain PostgreSQL (without TimescaleDB)

Real Postgres can hold time-stamped rows, but without time-series indexing the lab gets none of the historian-specific concepts (hot/warm/cold tiers, swinging-door compression, continuous aggregates) that GICSP candidates need to understand. The best argument for plain Postgres is "zero new concepts to learn on top of what you already know" — exactly the argument *against* it for a lab whose purpose is learning the OT-specific patterns.

### Ignition Maker Edition (rejected for fit, not for quality)

Ignition is genuinely the best **real-world feel** of every option considered. Inductive Automation's Ignition platform is a Tier-1 SCADA product deployed in real plants; Maker is the same codebase under a free non-commercial license, including the Tag Historian module out of the box. It would replace this lab's entire historian+HMI story with a unified platform — which is exactly why **it is the wrong scope for Queue Item 1**:

- **It replaces FUXA rather than extends the stack.** FUXA 1.3.1 is load-bearing for the lab's existing Phase 2/3 work (13 Suricata SIDs are baselined against FUXA's Modbus polling pattern; MASTER.md Findings §21 and §22 document the 1.3.1 pin reasoning). Swapping FUXA for Ignition Perspective views would force re-baselining every IDS rule and re-validating five attack scenarios. That is not "add a historian" — it is "rebuild the HMI layer."
- **License phone-home is a real concern.** Third-party blog reports indicate Maker periodically checks license status with Inductive Automation servers, with reversion to trial mode after extended offline. This is unverified in Inductive's primary docs (per ADR 0001's Ignition Maker row). For a lab that may simulate network isolation as an attack scenario, an unverified phone-home is a risk against the very experiments the lab exists to run.
- **Wrong granularity.** Queue Item 1 is "add a historian + visualizer." Ignition is "replace your SCADA + add a historian + add a visualizer + adopt a vendor platform." Order-of-magnitude different lift.

**Future placement.** Ignition Maker is a strong candidate for a *separate* future project — an "Ignition-based SCADA reference lab" that goes on the resume after GICSP passes. That project would be designed around Ignition from the start, not retrofit on top of FUXA. Holding it as a future portfolio anchor, not a Queue Item 1 dependency.

### Chronograf (visualization)

Bundled with the InfluxData TICK stack as the InfluxDB 1.x/2.x admin UI. Still actively maintained (v1.11.3 released 2026-05-27, same day as this ADR). InfluxData's own docs steer v3 users to Grafana or "InfluxDB 3 Explorer" — Chronograf is no longer the recommended visualizer even within the InfluxData ecosystem. Skipped.

### Apache Superset (visualization)

SQL/BI tool, not a time-series operational dashboard. Strong fit on top of SQL-shaped historians (Timescale, ClickHouse) where you want ad-hoc exploration and sharing; weak fit on top of InfluxDB v2's Flux/InfluxQL model and on top of Prometheus-family stores (no SQLAlchemy dialect). Wrong tool for the job.

### Metabase OSS (visualization)

Open-source BI tool with strong PostgreSQL/ClickHouse support; **no first-party InfluxDB driver** (community feature request #13174 has been open for years). For an InfluxDB-backed stack, Metabase has nothing to offer. AGPLv3, same license posture as Grafana, but compatibility is the blocker.

### Redash (visualization)

Last stable release 2021-11-24; repo is active again under new maintainers but a 4-year gap between stable releases is a yellow flag for a security-themed lab where the chosen tools become attack surface. The active dev work is encouraging but not yet released — wait for Redash to ship a 2026 stable cut before reconsidering.

---

## References

### Image-pin verifications (performed 2026-05-27)

- **InfluxDB v2.9.1** — `gh release list influxdata/influxdb` (v2.9.1 dated 2026-05-12 as the most recent v2.x); install doc at `https://docs.influxdata.com/influxdb/v2/install/` (references `influxdb2-2.9.1_linux_amd64.tar.gz`); Docker Hub at `https://hub.docker.com/_/influxdb` (v2.x tags `2`, `2.8`, `2.8.0`, `2.9`, `2.9.1` available; `latest` flips to v3 Core on 2026-05-27)
- **Grafana 13.0.1-security-01** — `gh release list grafana/grafana` (Latest dated 2026-05-12); Docker Hub at `https://hub.docker.com/r/grafana/grafana/tags`
- **Telegraf 1.38.4-alpine** — `gh release list influxdata/telegraf` (v1.38.4 dated 2026-05-11); Docker Hub at `https://hub.docker.com/_/telegraf`

### Telegraf Modbus plugin

- README — `https://github.com/influxdata/telegraf/blob/master/plugins/inputs/modbus/README.md`
- Plugin doc — `https://docs.influxdata.com/telegraf/v1/input-plugins/modbus/`

### Background context citations

- Purdue Model placement of historians at Level 3: Checkpoint (`https://www.checkpoint.com/cyber-hub/network-security/what-is-industrial-control-systems-ics-security/purdue-model-for-ics-security/`), IT/OT Insider (`https://itotinsider.substack.com/p/isa-95-and-the-purdue-model-explained`)
- TRITON / TRISIS historian-pivot: Wikipedia summary citing the DOJ indictment of GLADKIKH (`https://en.wikipedia.org/wiki/Triton_(malware)`); FBI PIN 220325 (`https://www.ic3.gov/CSA/2022/220325.pdf`)
- Volt Typhoon: CISA AA24-038A (`https://www.cisa.gov/news-events/cybersecurity-advisories/aa24-038a`)
- Claroty Team82 historian-pivot research / CVE-2022-46732 disclosure (`https://claroty.com/team82/disclosure-dashboard/cve-2022-46732`)
- MITRE ATT&CK for ICS — Asset A0006 (`https://attack.mitre.org/assets/A0006/`), Technique T0810 (`https://attack.mitre.org/techniques/T0810/`)

### Future-work CVE targets (available, not planned)

- CVE-2024-30896 — InfluxDB v2 token enumeration (`https://nvd.nist.gov/vuln/detail/CVE-2024-30896`)
- CVE-2025-3260 — Grafana dashboard API authz bypass (`https://grafana.com/security/security-advisories/cve-2025-3260/`)
- CVE-2025-3454 — Grafana datasource proxy authz bypass (`https://grafana.com/security/security-advisories/cve-2025-3454/`)
- CVE-2024-1313 — Grafana snapshot authz bypass (`https://grafana.com/security/security-advisories/cve-2024-1313/`)
- CVE-2025-6023 — Grafana open-redirect-to-XSS chain (`https://blog.ethiack.com/blog/grafana-cve-2025-6023-bypass-a-technical-deep-dive`)

### Parallel research doc

- `C:\Users\jimmy\temp\historian-research-cc.md` (this Claude session, 2026-05-27) — full Q1–Q7 research that produced this stack choice, moved out of `/tmp` for retention.
