# ADR 0001 — Phase 3 stack: PLC and HMI candidates

**Date:** 2026-05-25
**Status:** Accepted
**Scope:** Architectural decision for the lab's PLC and HMI roles entering Phase 3
**Triggering rule:** Tool-selection gate codified mid-Phase-2 in `~/.claude/CLAUDE.md` (project-start tool-selection-gate, ≥3 candidates per role, upstream-deprecated = hard stop)
**Empirical work:** OpenPLC v4 GHCR image pulled and characterized in this session; FUXA 1.3.2 release notes and merged PRs verified against vendor sources; vendor-doc verification for all other candidates by primary-source fetch.

---

## Plain-English summary

The lab will keep FUXA (bumping from 1.3.1 to 1.3.2 — same vendor, minor version) for the HMI, and replace OpenPLC v3 with OpenPLC v4 for the PLC. The reason for the PLC swap is simple: OpenPLC v3 was formally archived by its maintainer on 2026-04-04 — its repo is now read-only with an "End of Life" notice — and the tool-selection rule says we cannot stay on archived upstream code. The reason for keeping FUXA is also simple: switching to any other HMI would force re-validating all 13 Suricata detection rules and all 5 attack scenarios against a different vendor's Modbus polling pattern, and no candidate is enough better to justify that cost. FUXA 1.3.2 is the same vendor with active maintenance and a release six days ago that adds heartbeat infrastructure relevant to the Phase 2 reconnect bug.

The PLC migration is real work — OpenPLC v4 is architecturally different from v3, and a chunk of the Phase 2 findings will need re-validation against the new runtime. That work belongs to Phase 3 itself, not to this ADR. This ADR commits to the destination; the migration is the Phase 3 starting task.

---

## Context

The lab was built in Phase 1 with OpenPLC v3 + FUXA 1.3.1 chosen by default rather than by formal evaluation. Mid-Phase-2 we codified the tool-selection rule (≥3 candidates per role, deprecation status checked, platform-fit verified) and noted that the rule applied retroactively to the foundational stack. This ADR closes that retroactive gap before Phase 3 starts.

Two roles in scope:

- **PLC role** — runs IEC 61131-3 control logic (this lab's `tank_fill.st`), exposes Modbus/TCP at port 502
- **HMI role** — speaks Modbus/TCP as a client, renders operator screen, runs in a Docker container

Both must run on Docker Desktop on Windows with WSL2 backend (the lab's platform). Platform fit is a verified column, not an assumed one — the Phase 2 step 3c lesson (Docker Desktop host-mode L4-only) is the cautionary precedent.

---

## PLC role evaluation

### Triage — disqualified candidates

| Candidate | Reason |
|---|---|
| **OpenPLC v3** | Formally archived on `github.com/thiagoralves/OpenPLC_v3` on 2026-04-04 with explicit EOL notice. Tool-selection-rule hard stop. |
| **Codesys Control for Pi SL** | Free-for-eval license stops the runtime after 2 hours without a paid application license. Wrong fit for a learning lab where the runtime would need restarting twice per workday. Source: `store.codesys.com/en/codesys-control-for-raspberry-pi-sl.html` |
| **pyModbus** | Python Modbus-protocol library only. No IEC 61131-3, no ladder / ST / FBD. Cannot run `tank_fill.st`. Disqualified by role requirements (Modbus server ≠ PLC), not by maturity. Source: `github.com/pymodbus-dev/pymodbus` |

### Viable candidates

#### OpenPLC v4 (Autonomy-Logic)

| Attribute | Value |
|---|---|
| Repository | `github.com/Autonomy-Logic/openplc-runtime` + `github.com/Autonomy-Logic/openplc-editor` |
| Latest release | Runtime v4.0.9 (2026-03-05); Editor v4.1.1 (2026-01-09) |
| Licensing | Open source |
| IEC 61131-3 support | Yes — Editor compiles ST/LD/FBD/SFC/IL programs and uploads via REST API |
| Modbus/TCP support | Via `modbus_slave` Python plugin — see Known Limitations |
| Docker availability | `ghcr.io/autonomy-logic/openplc-runtime:latest` (multi-arch amd64/arm64/armv7). **NOT on Docker Hub** — compose `image:` line must point at GHCR. Pulled successfully in this session; image size 356 MB. Docs: `github.com/Autonomy-Logic/openplc-runtime/blob/main/docs/DOCKER.md` |
| Platform fit on Docker Desktop on Windows + WSL2 | Verified empirically this session — `docker pull` from GHCR works; container starts; REST API at 8443 reachable from host |
| Industry adoption | Education / prototyping / non-critical commercial. Vendor + third-party coverage (`control.com`, `plcprogramming.io`) explicitly position the project as not for safety- or mission-critical production. For a security teaching lab this is the right ceiling. |
| Known limitations | **(empirically verified this session)** Image EXPOSEs only 8443/tcp. A freshly-started container listens only on `0.0.0.0:8443`, NOT on 502. No `drivers.cfg` ships in the image. Modbus listening requires (a) operator-supplied `drivers.cfg` configuring `modbus_slave` plugin path, AND (b) PLC in RUN state. Different from v3's "container up = Modbus on :502 listening" model. |
| Phase 2 finding regression risk | **Material.** Finding §3 (web UI on 8080/8443) — v4 has no web UI, only REST on 8443. SID 9000004 (TCP SYN to OpenPLC web UI from non-operator) needs re-shaping or retirement. Finding §4 (silent-zero out-of-map reads) is plugin-implementation-dependent and must be re-verified. Findings §5–§7 (write semantics + §5.3 reassertion) must be re-verified against v4's plugin Modbus path. |
| IDS rules regression risk | **Moderate.** SIDs 9000010–9000015 + 9000020/21 use the Modbus app-layer keyword and don't depend on PLC implementation, but the polling cadence and FC mix the rules implicitly tune against will shift if FUXA polls a different OpenPLC v4 plugin response shape. SID 9000004 likely retires (no web UI on 8080). |
| Migration cost | **Substantial.** Editor is a separate desktop application (wxPython). Program upload is REST/JWT, not file-copy. drivers.cfg authoring is new operator work. Phase 3 starting task. |

#### Beremiz

| Attribute | Value |
|---|---|
| Repository | `github.com/beremiz/beremiz` |
| Latest release | Tagged 1.4-rc1 (2024-05-28); `main` branch active with commits as recent as 2026-05-12 |
| Licensing | Open source (GPLv2) |
| IEC 61131-3 support | Yes — full IEC suite via the IDE |
| Modbus/TCP support | Via runtime extension |
| Docker availability | **No official image.** Third-party `skvorl/beremiz-service` exists but is not vendor-sanctioned. Source-build only is the documented path. |
| Platform fit on Docker Desktop on Windows + WSL2 | **Poor.** IDE is a wxPython desktop application that connects to the runtime over Pyro (Python RPC) at default port 3000. The documented happy path is IDE-and-runtime-co-located. Split-deployment (IDE on host, runtime in container) over a container network boundary is not in the official docs (`beremiz.readthedocs.io/en/latest/manual/connectors.html`) and is brittle. No GitHub issues or community docs address Docker Desktop on Windows / WSL2 specifically. |
| Industry adoption | Niche. Used in some European industrial-automation research contexts; not a typical first-tier choice in OT/ICS practitioner communities. |
| Known limitations | Pyro 3 dependency (legacy Python RPC framework). Documentation is sparse compared to OpenPLC. |
| Phase 2 finding regression risk | Severe — different runtime model would force re-validation of all Findings §3–§7. |
| IDS rules regression risk | Severe — different Modbus polling shape, different FC implementation behavior. |
| Migration cost | Very high — requires solving the Docker-split-deployment problem before any control logic runs. |

### PLC decision

**OpenPLC v4** (over Beremiz).

The decision turns less on absolute capability than on platform fit for this specific lab. Beremiz's IDE/runtime Pyro split has no documented Docker recipe for Windows + WSL2, and the lab's first-run experience on that path would be hours of debugging Pyro-over-bridge networking before the operator could write their first ST program. OpenPLC v4's REST + desktop-editor model is well-documented for Docker, the image is on GHCR with multi-arch builds, and the empirical pull-and-run worked first try in this session.

The OpenPLC v4 plugin architecture is genuinely more complex than v3's (drivers.cfg + RUN-state gating + separate Editor process). That complexity must be characterized and documented during the Phase 3 migration; the empirical findings from this session ("Modbus :502 silent until drivers.cfg + RUN") seed that work.

---

## HMI role evaluation

### Triage — disqualified candidates

| Candidate | Reason |
|---|---|
| **ScadaBR** | Dead (last real release 2021-09-07; README touch 2023-02-04). **Plus** CISA advisory ICSA-26-139-03 published 2026-05-19 documenting four CVEs (CVE-2026-8602 through CVE-2026-8605) including unauthenticated RCE, with vendor unresponsive to CISA outreach. Hard stop regardless of the staleness alone. |
| **Node-RED Dashboard v1** | Officially deprecated 2024-06-27 by maintainers. Successor is Dashboard 2.0 (FlowFuse). |

### Reconnect-bug framing (applies to every HMI candidate)

Phase 2 Finding §10 framed FUXA 1.3.1's lack of Modbus auto-reconnect as a FUXA-specific issue. Subsequent research showed this is an **ecosystem-wide** problem affecting libmodbus, plc4x, pymodbus AsyncModbusTcpClient (issue #2499), node-red-contrib-modbus (issue #236), Home Assistant Modbus integration (issue #68161), and reportedly Inductive Automation's Ignition forum threads. Every Modbus-client HMI candidate must therefore be evaluated on **configurability and quality of reconnect handling**, not on a binary yes/no.

### Viable candidates

#### FUXA 1.3.2

| Attribute | Value |
|---|---|
| Repository | `github.com/frangoteam/FUXA` |
| Latest release | v1.3.2 (2026-05-19, six days before this ADR) |
| Licensing | MIT |
| Modbus/TCP client | Yes (current lab uses this against OpenPLC) |
| Docker availability | `frangoteam/fuxa:1.3.2` on Docker Hub (verified). Tag pinning matches lab convention. |
| Platform fit on Docker Desktop on Windows + WSL2 | Verified by existing lab — Phase 1 + Phase 2 ran on this stack for months without platform-class issues. |
| Industry adoption | OT-lab and small-deployment community common. Used in independent ICS-cyber-training labs (search GitHub topic "fuxa" returns lab projects). Not a top-tier enterprise SCADA vendor — appropriate ceiling for a learning lab. |
| Known limitations | Phase 2 Finding §10 (Modbus client has no auto-reconnect) was documented against 1.3.1. **1.3.2 release notes do not explicitly call out a reconnect fix.** PR #2016 (heartbeatIntervalSec) was merged 2025-11-09 — already in 1.3.1 and 1.3.2. PRs #2078/2079/2082 (Electron updates including "retry connect logic when starting") are in 1.3.0+ — these are Electron-app start-path fixes, not Modbus device-client fixes. Empirical re-test of the reconnect behavior on 1.3.2 is a Phase 3 starting task. |
| Phase 2 finding regression risk | Minimal — same vendor, minor version bump. Findings §1–§12 largely unaffected. |
| IDS rules regression risk | Minimal — same Modbus client implementation, same polling cadence baseline. All 13 SIDs and 5 scenarios stay valid. |
| Migration cost | Trivial — compose `image:` tag bump from `:1.3.1` to `:1.3.2`. |

Source: `github.com/frangoteam/FUXA/releases/tag/v1.3.2`, PRs `/2016`, `/2078`, `/2079`, `/2082`.

#### Ignition Maker Edition

| Attribute | Value |
|---|---|
| Vendor | Inductive Automation |
| Latest version | Ignition 8.1 (Maker is a license tier on the main Ignition platform) |
| Licensing | Free for non-commercial personal use. Per vendor: "Maker Edition may only be used by individuals for personal use. Businesses, non-profit organizations, and other entities cannot use Maker Edition for commercial, revenue-generating, or non-profit activities." (Source: `inductiveautomation.com/ignition/maker-edition`) |
| Modbus/TCP client | Yes (Modbus driver module). |
| Docker availability | **No Maker-Edition Docker image published by vendor.** Generic Ignition Docker images exist on Docker Hub from Inductive Automation but Maker licensing in those is not documented for portability. |
| Platform fit on Docker Desktop on Windows + WSL2 | Inductive's Docker support is documented for Linux Docker; Windows-specific Docker Desktop fit is not vendor-attested for the Maker tier. |
| Industry adoption | Ignition (commercial editions) is a top-tier real-world SCADA platform — Tier-1 plants, refineries, water utilities. Maker is the hobby/learning tier off the same codebase. This is the strongest "real-world feel" of all the HMI candidates. |
| Known limitations | **(1)** Vision module is NOT in Maker; Perspective only. **(2)** Caps: 10,000 tags, 10 concurrent Perspective sessions, 3 gateways max per individual. **(3)** License phone-home / offline behavior — third-party blogs report a periodic check-in with reversion to trial after extended offline, but **this is unverified in Inductive's primary docs**; for a lab that simulates network isolation as Phase 3 attack scenarios, an unverified phone-home behavior is a real risk against the very experiments the lab exists to run. **(4)** Non-commercial license restricts portfolio-presentation use to "individuals" — fine for showing recruiters; explicitly not for business / commercial / non-profit deployment. |
| Phase 2 finding regression risk | High — different Modbus client implementation, different polling cadence, different default FC mix. |
| IDS rules regression risk | High — every Modbus-keyword rule (9000010–9000015, 9000020/21) re-baselined against Ignition's traffic shape. |
| Migration cost | Very high — new vendor, new authoring workflow (Perspective views), license setup, docker pattern unknown for Maker. |

Source: `inductiveautomation.com/ignition/maker-edition`, `docs.inductiveautomation.com/docs/8.1/other-editions/ignition-maker-edition`.

#### Scada-LTS

| Attribute | Value |
|---|---|
| Repository | `github.com/SCADA-LTS/Scada-LTS` |
| Latest release | v2.7.8.1 (2025-03-31); pre-release v2.8.0_pre (2025-10-17). Active fork of the ScadaBR lineage. |
| Licensing | GPL |
| Modbus/TCP client | Yes (inherited from ScadaBR codebase, actively patched). |
| Docker availability | `scadalts/scadalts:latest` on Docker Hub (verified). Vendor-supplied `docker-compose.yml` runs three containers: `mysql/mysql-server:8.0.32`, `scadalts/scadalts`, `hivemq/hivemq4`. Tomcat is bundled inside the Scada-LTS image. Image size ~356 MB compressed. |
| Platform fit on Docker Desktop on Windows + WSL2 | Standard Linux-container workload; no WSL2-specific gotchas documented. Footprint concern below. |
| Industry adoption | OT-lab precedent direct: GitHub topic `scada-lts` surfaces an "ICSs virtualized lab for cybersecurity testing" combining OpenPLC + Scada-LTS + GNS3 + docker-compose. So this stack pairing is community-vetted for the lab use case. |
| Known limitations | **(1)** Heavier footprint than FUXA: MySQL + HiveMQ + Tomcat-bundled-Scada-LTS = three containers, ~600 MB+ memory baseline before workload. Docker Desktop on Windows + WSL2's known OOM-kill-under-load gotcha is most likely to bite here. **(2)** PR #2089 ("Fix vulnerabilities reported in #1734") merged 2022-02-18 — they are actively patching the ScadaBR CVEs that killed the upstream. |
| Phase 2 finding regression risk | High — different Modbus client, different polling cadence. |
| IDS rules regression risk | High — same reasons as Ignition. |
| Migration cost | High — new vendor authoring workflow, new compose shape, footprint testing required. |

Source: `github.com/SCADA-LTS/Scada-LTS`, `hub.docker.com/r/scadalts/scadalts`.

#### Node-RED Dashboard 2.0 (FlowFuse)

| Attribute | Value |
|---|---|
| Repository | `github.com/FlowFuse/node-red-dashboard` |
| Latest release | v1.30.2 (2026-01-21); latest commit on default branch 2026-05-19 |
| Licensing | Apache-2.0 |
| Modbus/TCP client | Not native to Dashboard 2.0 itself. Paired with `node-red-contrib-modbus` (v5.45.2, ~2025-10). Reconnect behavior since 5.22+: package catches network/server errors but pushes recovery onto flow authors via error-event handling, not automatic reconnect. Source: `flows.nodered.org/node/node-red-contrib-modbus`. |
| Docker availability | No standalone Dashboard 2.0 container — it's a palette inside Node-RED. Node-RED itself has official Docker images. |
| Platform fit on Docker Desktop on Windows + WSL2 | Node-RED runs fine on Docker Desktop; Dashboard 2.0 inherits the platform fit. |
| Industry adoption | DOE CyberFire OT-1 course explicitly uses Node-RED as HMI for ICS training (`cyberfire.energy.gov/classes/ot-1/` — "Introduction to HMIs via Node Red flow programming"). **This is training/education adoption, not production-SCADA HMI adoption.** Stating that honestly: Node-RED is a great learning HMI but you would not see it deployed in an actual plant control room. |
| Known limitations | Reconnect is flow-author responsibility (per ecosystem-wide framing above), not declarative configuration. UI styling is more "developer dashboard" than "operator HMI" — would feel different from FUXA's gauge/switch metaphor. |
| Phase 2 finding regression risk | Severe — completely different Modbus client implementation, completely different polling cadence (flow-driven, not driver-driven). |
| IDS rules regression risk | Severe — every Modbus-keyword rule re-baselined. |
| Migration cost | Very high — re-authoring of all 5 scenarios' HMI side and re-validation of all 13 SIDs. |

Source: `github.com/FlowFuse/node-red-dashboard`, `flows.nodered.org/node/node-red-contrib-modbus`, `cyberfire.energy.gov/classes/ot-1/`.

### HMI decision

**FUXA 1.3.2** (over Ignition Maker, Scada-LTS, Node-RED Dashboard 2.0).

The deciding columns are **Phase 2 finding regression risk + IDS rules regression risk + Migration cost**. All three of those favor staying with FUXA by a wide margin — same vendor, minor version bump, same Modbus client implementation. None of the alternatives is sufficiently better at the security-lab role to justify re-baselining 13 SIDs and re-shaping 5 scenarios.

Each alternative dismissed has a real case behind it:

- **Ignition Maker** is the most "real-world feel" — Inductive Automation is a Tier-1 SCADA vendor — but the unverified phone-home behavior and the no-Maker-Docker-image situation are blockers for a lab that simulates network isolation. The non-commercial license clause is acceptable for portfolio use but constrains optionality.
- **Scada-LTS** has a direct OT-lab precedent (the GitHub-topic "ICSs virtualized lab"), is actively patching the CVEs that killed ScadaBR, and is the most footprint-concerning candidate against Docker Desktop's known OOM-kill behavior.
- **Node-RED Dashboard 2.0** is the lightest-footprint option and has DOE CyberFire training-course adoption, but the reconnect-responsibility-on-flow-author model is the *opposite* direction from where the ecosystem reconnect framing pushes us, and the "feels like a developer dashboard" UI is a worse operator-screen analog.

The minimum-regression choice is FUXA 1.3.2. The Phase 2 reconnect bug remains until empirically re-tested against 1.3.2 — that re-test is a Phase 3 starting task, not blocking this ADR.

---

## Consequences

### What changes in Phase 3

1. PLC compose service migrates from custom `ot-ics-lab/openplc:v3-pinned` build (Debian Trixie + thiagoralves source commit) to `ghcr.io/autonomy-logic/openplc-runtime:<pinned-tag>`. The local Dockerfile in `plc/` may retire (TBD during migration).
2. HMI compose service `image:` line bumps from `frangoteam/fuxa:1.3.1` to `frangoteam/fuxa:1.3.2`.
3. A drivers.cfg authoring step is added to the lab bring-up procedure for OpenPLC v4.
4. The desktop OpenPLC Editor (Autonomy-Logic/openplc-editor) becomes a Phase 3 operator dependency — installs on Windows, talks to the container over REST.
5. `tank_fill.st` is re-uploaded via the v4 REST upload path; existing source kept verbatim if v4's ST compiler accepts it as-is (to be verified).

### Findings to re-validate during Phase 3 migration

- **§3** (web UI on 8080 + 8443) — v4 has no web UI on 8080; only REST on 8443. SID 9000004 needs re-shape or retirement.
- **§4** (out-of-map reads return silent zeros, not exception 02) — plugin-implementation-dependent; re-verify against v4 modbus_slave plugin.
- **§5** (§5.3 reassertion across all four output FCs) — re-verify against v4 plugin Modbus path.
- **§6** (operational deception coil-write) — re-verify; expected to hold but plugin path may surface different behavior.
- **§7** (no auth / no integrity) — protocol-level finding, expected to hold trivially.
- **§10** (FUXA Modbus auto-reconnect absence) — re-test empirically against 1.3.2 with the existing healthcheck mitigation in place.

### IDS rules to re-baseline during Phase 3

- SIDs 9000010–9000015 + 9000020/21 — re-replay scenario-2 through scenario-5 pcaps against a v4 + FUXA-1.3.2 lab to confirm counts still match prediction.
- SID 9000004 (web UI :8080/:8443 from non-operator) — likely retire under v4 (no web UI).

### Held items / risks accepted

- OpenPLC v4 Modbus-listening-state empirically characterized as "silent until drivers.cfg + RUN" in this session. Phase 3 migration must include drivers.cfg authoring + lab bring-up instructions update.
- FUXA 1.3.2 reconnect behavior unconfirmed from release notes alone. Empirical re-test is a Phase 3 starting task — the existing healthcheck from 626fc56 remains in place until proven unnecessary.
- Ignition Maker's offline phone-home behavior was the only column I could not verify from primary vendor docs. Third-party reporting exists but is not authoritative. This ADR does not depend on resolving that question — Ignition Maker was already rejected on other grounds — but if it ever becomes a re-evaluation candidate, vendor-direct confirmation is needed before lab adoption.

---

## Sources

Primary sources cited inline above. Consolidated:

- `github.com/thiagoralves/OpenPLC_v3` (archive notice, 2026-04-04)
- `github.com/Autonomy-Logic/openplc-runtime` (current OpenPLC v4 home)
- `github.com/Autonomy-Logic/openplc-runtime/blob/main/docs/DOCKER.md` (v4 Docker docs)
- `github.com/Autonomy-Logic/openplc-editor` (v4 desktop editor)
- `ghcr.io/autonomy-logic/openplc-runtime` (v4 image registry; verified pull this session)
- `github.com/beremiz/beremiz` (Beremiz repo)
- `beremiz.readthedocs.io/en/latest/manual/connectors.html` (Pyro connector docs)
- `store.codesys.com/en/codesys-control-for-raspberry-pi-sl.html` (Codesys eval license)
- `github.com/pymodbus-dev/pymodbus` (pyModbus library)
- `github.com/frangoteam/FUXA/releases/tag/v1.3.2` (FUXA 1.3.2 release)
- `github.com/frangoteam/FUXA/pull/2016` (heartbeatIntervalSec PR)
- `github.com/frangoteam/FUXA/pull/2078`, `/2079`, `/2082` (Electron updates)
- `inductiveautomation.com/ignition/maker-edition` (Maker license terms)
- `docs.inductiveautomation.com/docs/8.1/other-editions/ignition-maker-edition` (Maker docs)
- `github.com/SCADA-LTS/Scada-LTS` (Scada-LTS active fork)
- `hub.docker.com/r/scadalts/scadalts` (Scada-LTS Docker images)
- `github.com/FlowFuse/node-red-dashboard` (Dashboard 2.0)
- `flows.nodered.org/node/node-red-contrib-modbus` (Modbus palette)
- `cyberfire.energy.gov/classes/ot-1/` (DOE CyberFire OT-1 course Node-RED claim)
- CISA advisory ICSA-26-139-03 (ScadaBR CVE-2026-8602 through -8605)

Empirical verifications performed this session:

- `docker pull ghcr.io/autonomy-logic/openplc-runtime:latest` — succeeded; 356 MB; amd64; entrypoint `bash ./start_openplc.sh`
- Image EXPOSE list contains only `8443/tcp`
- Fresh-container listening sockets: only `0.0.0.0:8443`
- `/workdir/venvs/{modbus_slave,modbus_master,opcua,runtime}` exist but no `drivers.cfg` ships in the image

---

## Corrections forward (appended 2026-05-26 at Phase 3 migration close)

The body of this ADR above remains exactly as committed at `bf69781`
(2026-05-25). Empirical work during Stops 1–6 surfaced five reframes
to the original ADR's framing; per doc-edit-triage discipline, none of
the body is rewritten — these are inline-acknowledged here so a future
reader doesn't take the original text out of context.

### 1. Configuration filename — drivers.cfg → plugins.conf

The ADR uses "drivers.cfg" terminology throughout the Consequences
section and the OpenPLC v4 Known Limitations row. **The actual v4
source loads `./plugins.conf`** (relative to `/workdir`), per:

- `core/src/plc_app/plc_main.c:108` (v4.0.9) / `:110` (v4.1.0):
  `plugin_driver_load_config(plugin_driver, "./plugins.conf")`
- `core/src/plc_app/plc_state_manager.c:246` (v4.0.9) / `:254` (v4.1.0):
  `plugin_driver_update_config(plugin_driver, "./plugins.conf")`

Format unchanged from what the ADR described: CSV with columns
`name,path,enabled,type,plugin_related_config_path,venv_path`, parsed
by `core/src/drivers/plugin_config.c:42`. The lab's runtime config file
lives at `plc/v4/plugins.conf` and is bind-mounted to
`/workdir/plugins.conf` (read-only) — see MASTER.md §15.

### 2. Modbus listening — two gates → four gates

The ADR's OpenPLC v4 Known Limitations row described Modbus as "silent
until plugins.conf [drivers.cfg] supplied AND PLC in RUN state" — two
gates. **The actual gate chain is four conditions**, all required:

1. `plugins.conf` exists with `modbus_slave` row enabled (gate 1)
2. The plugin's `config.json` overrides default port 5020 → 502 (gate 2)
3. A compiled `libplc_*.so` exists in `/workdir/build/` (gate 3 — output of an Editor-produced bundle uploaded via REST and compiled by the runtime's `scripts/compile.sh`)
4. PLC is in RUN state, transitioned via authenticated `GET /api/start-plc` (gate 4 — depends on gate 3)

Gates 1-2 are configurable via the bind mounts already shipped with the
lab. Gates 3-4 happen on every Build/Compile via the OpenPLC Editor v4
desktop application. See MASTER.md §15 + §17 for the empirical
verification and §20 for the related `update_plugin_configurations`
side effect.

### 3. Editor desktop application — "separate" → "mandatory"

The ADR's OpenPLC v4 row says "Editor is a separate desktop application
(wxPython)" and the Migration cost column says "Editor is a separate
desktop application." Two corrections:

- **The Editor is mandatory, not optional.** v4 Runtime has no MATIEC
  compiler; the bundle uploaded to `POST /api/upload-file` must contain
  MATIEC C output (`Config0.c`, `Res0.c`, `debug.c`, `glueVars.c`,
  `lib/`). Editor README line 66 is explicit: *"Compile in Editor — The
  Editor compiles locally (JSON → XML → ST → C files) and packages
  sources into program.zip"*. There is no operator path that bypasses
  the Editor for compile. See MASTER.md §16.
- **The Editor is Electron, not wxPython.** The "wxPython" framing was
  carried in from Beremiz comparison and was wrong for v4 Editor.
  v4 Editor (v4.1.4 installed in this lab) is an Electron desktop app
  with installer at `github.com/Autonomy-Logic/openplc-editor/releases`.

### 4. Version pin — "v4 line" → "v4.0.9 pinned" because v4.1.x is broken

The ADR's PLC decision said "OpenPLC v4 (Autonomy-Logic)" without
specifying patch. The image initially pulled was the moving `:latest`
tag, which resolved to `v4.1.0-rc.1` and then `v4.1.0` final. **Both
v4.1.x runtimes reject MatIEC bundles**, and Editor v4.1.x cannot
produce STruC++ output (zero `strucpp` source matches in either repo).
Empirically, **v4.0.9 is the last functional Editor↔Runtime combination**
and is what the lab pins to in compose. See MASTER.md §18.

Two upstream issues filed at Phase 3 close:

- [github.com/Autonomy-Logic/openplc-editor#781](https://github.com/Autonomy-Logic/openplc-editor/issues/781) — `validateRuntimeVersion` literal-compare bug
- [github.com/Autonomy-Logic/openplc-editor#782](https://github.com/Autonomy-Logic/openplc-editor/issues/782) — v4.1.x Editor cannot produce STruC++ bundles required by v4.1.x Runtime

### 5. HMI version pin — "FUXA 1.3.2" → "FUXA 1.3.1 retained"

The ADR's HMI decision section says "**HMI pick:** FUXA 1.3.2." Stop 4
attempted the bump and rolled it back. **FUXA 1.3.2 introduces an
undocumented plugin-architecture change that breaks pre-1.3.2 project
DBs** — same `project.fuxap.db` device row that loaded cleanly on 1.3.1
fails on 1.3.2 with `try to create OpenPLC but plugin is missing!`.
See MASTER.md §21.

The Gate 2 ADR's HMI rationale held that "same vendor minor version
bump" was the **continuity** signal, not a specific 1.3.2 dependency.
Staying on 1.3.1 satisfies the ADR's intent. The lab pin is now
`frangoteam/fuxa:1.3.1`. A future FUXA upstream issue is staged for
filing (`github.com/frangoteam/FUXA/issues`) — file:line evidence in
FUXA 1.3.2 source not yet collected; deferred to filing time.

### Summary of what stays unchanged

The ADR's **Decision** (OpenPLC v4 over Beremiz/Codesys/pyModbus for
PLC; FUXA over Ignition Maker/Scada-LTS/Node-RED Dashboard 2.0 for
HMI), the **dismissed alternatives**, the **column structure** of the
matrix, and the **Findings to re-validate** list — all stay
authoritative. The five corrections above are operator-facing details
that emerged during execution, not changes to the strategic choice.
