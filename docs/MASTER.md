# OT/ICS Security Lab — MASTER (Status & Index)

Single source of truth for this project's status, decisions, risks, and
document map. Vendor-neutral OT/ICS security lab — a portfolio /
recruiter-facing artifact where the *reasoning* behind each choice is part
of the deliverable, not just the plumbing.

- **Project:** Vendor-neutral OT/ICS security lab (portfolio / recruiter-facing)
- **Process simulated:** Generic plant tank-fill (level, pump, valve, high alarm)
- **Phase:** 1 of 3 (Phase 1 complete; Phase 2 = security work on v3, Phase 3 = platform migration + zone hardening)
- **Phase 1 status:** **Acceptance gate fully met — runtime, visual HMI, and Modbus/TCP capture all proven end-to-end** (see Acceptance Gate)
- **Last updated:** 2026-05-24
- **Repo:** `<repo-root>` (your local clone location; absolute path is environment-specific)

---

## Document Index

| File | Purpose |
|---|---|
| `README.md` | What it is, prerequisites, setup, run, test, screenshots, security talking points |
| `docs/architecture.md` | Components, control + process model, data flow, zones, trust boundaries |
| `docs/network-security.md` | Threat model, supply-chain control, least privilege, segmentation, exposure, attacker view |
| `docs/monitoring.md` | Wireshark Modbus capture (host + container paths), normal baseline vs. suspicious |
| `docs/MASTER.md` | This file — status, locked decisions, risks, Phase 2 and Phase 3 backlogs |
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
connection). Ready for public repo flip.

---

## Key Decisions Locked (recruiter-relevant)

| Decision | Choice | Why it matters |
|---|---|---|
| OpenPLC image | Built from pinned upstream commit `b5d4135…` | No unvetted Docker Hub image — supply-chain control is part of the security story |
| FUXA image | `frangoteam/fuxa:1.3.1` (pinned) | No moving `:latest`; reproducible |
| `--privileged` | **Not** set on OpenPLC | Deliberate least-privilege; no hardware I/O in this lab |
| `.env` file | None in Phase 1 | Fewer first-run failure modes for a beginner |
| Zoning | `ot_zone`, `mgmt_zone`, `attacker_zone` | `attacker_zone` is the genuinely enforced boundary — proof landed 2026-05-22 (Phase 2 Findings §1) |
| Suricata capabilities | `NET_ADMIN` + `NET_RAW` only (intentionally no `SYS_NICE`) | Permits `:ro` bind mounts on rules + config (supply-chain control: Suricata cannot tamper with its own ruleset at runtime even if compromised). Trade: cosmetic "running as root" startup warning, accepted — root inside a non-privileged container with no host access is not a security issue |
| FUXA Modbus healthcheck | Detection-only (no autoheal sidecar) | FUXA 1.3.1 ModbusTCP driver has no auto-reconnect (Finding §10). Healthcheck shipped at 626fc56 marks `fuxa` as (unhealthy) within ~90s of a silent drop; operator manually runs `docker compose up -d --force-recreate fuxa` to recover. Local-use lab; autoheal sidecar deferred to portfolio-prep phase post-cert |

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
- **OpenPLC startup crash if `Programs` table and `active_program` pointer
  drift apart** — observed 2026-05-21 after a Docker Desktop restart cycle.
  The named volume preserved `openplc.db`, but the `Programs` table row for
  the active program was missing while `/opt/OpenPLC_v3/webserver/active_program`
  still pointed at `927367.st`. At HTTP server startup `webserver.py:2726`
  runs `SELECT * FROM Programs WHERE File = '<active_program>'`; with no
  row it returns `None`, and the `run_http` thread dies with
  `TypeError: 'NoneType' object is not subscriptable`. The web UI (`:8080`)
  is then unreachable and the Modbus runtime never starts (it needs a
  loaded program). Recovery — restore the missing row from inside the
  container. The underlying cause is OpenPLC v3's lack of transactional
  linkage between the pointer file and the database row, not a bug in
  the lab; the recovery below is verified persistent across a subsequent
  full `docker compose down`/`up -d` cycle (`curl -I http://localhost:8080`
  returns `HTTP/1.1 302`, FUXA reconnects):

  ```bash
  # 1. Read the pointer to get the active program filename
  docker exec otlab-openplc cat /opt/OpenPLC_v3/webserver/active_program

  # 2. Insert the matching Programs row (substitute the filename from step 1)
  docker exec otlab-openplc sqlite3 /opt/OpenPLC_v3/webserver/openplc.db \
    "INSERT INTO Programs (Name, Description, File, Date_upload) VALUES \
     ('Tank Fill', 'Generic plant tank-fill process', '<filename>', strftime('%s','now'));"

  # 3. Restart so OpenPLC re-reads state
  docker compose restart openplc
  ```
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
- 2026-05-21 — Persistence of a named volume kept the data, but OpenPLC's
  own startup code is brittle if internal state files (`active_program`
  pointer, `Programs` DB rows) drift out of sync. Process improvement:
  persistence alone is insufficient — for stateful services with
  multi-file consistency requirements, document the recovery procedure
  as a Known Risk, not as a tribal-knowledge incident response.
- 2026-05-21 — a verification spike on an unfamiliar Docker image (OpenPLC
  v4) caused Docker Desktop to terminate the running Phase 1 containers to
  free memory for the new image's startup. Phase 1 recovered cleanly in
  8 seconds — the previous day's named-volume persistence work was
  inadvertently stress-tested and passed (live Modbus value within one
  verification cycle). Process improvement: before pulling or running a
  large unfamiliar Docker image on a Windows/WSL2 host, either raise Docker
  Desktop's memory limit first, or `docker compose stop` the existing stack
  to give the new image headroom — resilience to a forced shutdown is not
  a license to invite one.
- 2026-05-23 — Verifying CLI flags against `--help` before using
  non-canonical long forms saves a failed run. Suricata accepts only
  `-l <dir>` for log directory; `--log-dir` is not exposed as a long alias.
  My initial replay used `--log-dir` — Suricata's parser silently ignored
  the unknown flag, fell through to help text, exited 0; output dir was
  never created and eve.json was never produced. Process improvement: for
  any tool where the short form is the documented standard, run
  `<tool> --help | grep -i <option-name>` before using the assumed long
  form. Discipline applies broadly, not just to Suricata.
- The discipline above is codified as a user-level Claude Code skill at
  `~/.claude/skills/verifying-cli-flags/SKILL.md` — triggers when about to
  use a long-form CLI flag (`--flag`) not yet confirmed in this project's
  history or the tool's `--help` output. Portable across projects (lives
  in user-level config, not the repo). RED-phase tested 2026-05-23 against
  two subagent scenarios; skill fired correctly on iptables long-form flag,
  stayed silent on a canonical git command.
- 2026-05-24 — **Verify runtime claims against current state, not against
  prior docs.** When a doc describes runtime state (IPs, container state,
  file contents, version pinning, etc.), verify against current state via
  live inspection (`docker inspect`, `ls`, `cat`) or commit history before
  propagating claims from prior docs. Prior docs may be stale relative to
  commits that landed after them. Lesson source: 2026-05-24 caught a
  triple-stale claim — the 3a evidence doc (shipped 2026-05-23 at b7d9661)
  said "Suricata is currently not pinned." Pinning shipped hours later at
  a91f5e2 but the 3a doc was never updated. When writing 3b's evidence doc
  on 2026-05-24, I inherited the stale claim by referencing the 3a doc
  instead of running `docker inspect otlab-suricata`. The stale framing
  propagated into project memory and into the next-day prompt for
  "task 3 — pin Suricata's IPs." Corrected at 956ce3d (in-place doc fixes
  for both 3a and 3b).
- 2026-05-24 — **Tool selection at project start / phase boundary requires
  a candidates evaluation before building.** Minimum 3 candidates per role,
  evaluated for: last commit date, deprecation status, open issue volume,
  known limitations (search `"{tool} reconnect/limitations/deprecated"`),
  what real industry uses. Output as a decision-matrix doc in the repo.
  **Upstream-deprecated = hard stop unless explicit justification with
  migration plan.** This is a gate, not a suggestion. Lesson source:
  retrospective on Phase 1 tool choices. OpenPLC v3 was chosen as the
  PLC by default and is upstream EOL — only discovered during the
  2026-05-21 verification spike on v4 (Phase 3 backlog now carries a
  full v3→v4 migration as a dedicated phase). FUXA 1.3.1's missing
  Modbus auto-reconnect (Finding §10) was discovered mid-Phase-2 only
  when the HMI silently froze. Both would have been caught by a
  pre-Phase-1 candidates evaluation. The cost of a 1-hour evaluation up
  front would have been much smaller than the cost of working around
  these limitations mid-phase.

---

## Open Items (Phase 1 follow-ups — not blocking acceptance)

- FUXA HMI layout polish — numeric `%` label floats per value width
  (`33%` / `48%` / `68%` shift horizontally), minor alignment between the
  Pump/Valve/Alarm indicator row. Acceptable for Phase 1; track as a
  Phase 2 polish item, non-blocking.

---

## Phase 2 Findings

Live security findings as Phase 2 work progresses. Each finding is dated
and tagged with the task that produced it. Pattern matches Phase 1
network-security §5.3's "prove the boundary, then prove what crossing it
costs" — first the boundary holds, then later tasks intentionally cross
it to document what becomes possible.

### 1. `attacker_zone` → `ot_zone` boundary holds (2026-05-22)

**Source:** Phase 2 step 1 — attacker container brought up on `attacker_zone`.

**Setup.** New container `otlab-attacker` attached to `attacker_zone`
only. Inside the container: one non-loopback interface (`eth0` on
`172.20.0.2/16` — the auto-assigned `attacker_zone` bridge), no second
NIC, no route to `ot_zone`'s subnet. Outside: `docker inspect` confirms
single-network attachment.

**Test 1 — name resolution.** `ping openplc` from inside the attacker.
Result: `ping: openplc: Name or service not known` (exit 2). Docker's
embedded DNS is scoped per bridge — `openplc` is registered on
`ot_zone`, not on `attacker_zone`, so name resolution itself fails.

**Test 2 — TCP reach.** TCP knock to `openplc:502` (the Modbus port)
from inside the attacker, with a 3-second cap:

```bash
docker exec otlab-attacker bash -c \
  "timeout 3 bash -c '</dev/tcp/openplc/502' && echo OPEN || echo BLOCKED"
```

Result: `BLOCKED` after the 3-second timeout — no route, no peer.

**Evidence quality.** Phase 1 services (`otlab-openplc`, `otlab-fuxa`)
were running on `ot_zone` at the time of the test (5+ minutes uptime).
The failure is therefore not "openplc was down anyway" — it is
"openplc was alive and serving Modbus on `ot_zone`, but `attacker_zone`
could not reach it."

**Interpretation.** Docker bridge-network isolation alone is sufficient
to prevent an `attacker_zone` container from addressing `ot_zone` — at
both the resolution layer (DNS scoped per bridge) and the routing layer
(no route between bridges). This is the architectural claim made in
`docs/network-security.md` and README talking point #4, now empirically
demonstrated. Phase 2 step 2's Step 4 verification (2026-05-22) added a
direct-IP probe (`172.18.0.2:502` from `attacker_zone`) that also
returned BLOCKED — the two layers are therefore independent failures,
not a single combined one.

**Resolved in Phase 2 step 2 (2026-05-22).** The three deferred tests
were executed in the attack-scenarios task:

- **Direct-IP reach** is independently blocked. Step 4 verification
  probes `172.18.0.2:502` (openplc's ot_zone IP) from `attacker_zone`
  and gets `BLOCKED` — same as the name-based probe. The boundary's
  two layers (DNS scoped per bridge + inter-bridge routing absent)
  are therefore independent failures, both confirmed.
- **Positive control** is implicit in scenarios 1–5: once the
  attacker is attached to `ot_zone`, everything works. The §1
  boundary is real, not a misconfigured test environment.
- **Modbus writes that succeed once the boundary is crossed** —
  empirical inventory now in Findings §5 and §7. The
  `docs/network-security.md` §5.3 scope-honesty note is fully closed
  across all four output write FCs.

### 2. `mgmt_zone` vs `ot_zone` — what's actually on the wire (2026-05-22)

**Source:** Pre-flight of the Phase 2 attack-scenarios task (the
baseline pcap surfaced this; cited in scenarios 1 and 5 setup).

**Summary:** The Phase 1 architecture story frames `ot_zone` as the
process/Modbus network. Empirically, the running FUXA↔OpenPLC Modbus
poll rides `mgmt_zone` (172.19.0.x), not `ot_zone` (172.18.0.x). Both
services are multi-homed; Docker's embedded DNS happened to resolve
`openplc` to its mgmt_zone IP when FUXA opened its long-lived
connection, and that connection has persisted on mgmt_zone since.
`docs/network-security.md` §4's honest-scope note (mgmt_zone↔ot_zone
is not a hard boundary) covers this; the practical consequence is
that the legitimate poll path in this lab's current runtime state is
mgmt_zone-only.

**Implication:** Suricata sensor placement (Phase 2 backlog item)
must choose ot_zone vs mgmt_zone vs both. ot_zone-only would miss the
legitimate FUXA baseline; mgmt_zone-only would miss attacker traffic
after a boundary cross. Phase 3 mgmt_zone↔ot_zone hardening also
needs to know which network the live legitimate traffic actually
traverses today.

### 3. Recon on `ot_zone` is unimpeded; OpenPLC web UI also serves HTTPS on 8443 — a documentation-drift hardening trap (2026-05-22)

**Source:** Scenario 1 — `docs/phase2/scenarios/scenario-1-recon-nmap.md`.

**Summary:** nmap host discovery + service detection from an
ot_zone-attached attacker completes in ~2 min and surfaces every
documented service. **A previously undocumented port — openplc:8443
— is also open**, running the same Flask/Werkzeug webserver as the
documented :8080 OpenPLC web UI (matching `Server: Werkzeug/2.3.7
Python/3.13.5` header, same `python3 webserver.py` PID, same
application). HTTPS via Flask's adhoc SSL context — a second access
path to the OpenPLC management UI. The Phase 1 host-published port
table (`docs/network-security.md` §5.1) lists only :8080. HTTP
listeners (8080, 1881) also leak framework + version information in
`Server:` headers.

**Implication:** **Documentation-drift hardening trap.** Phase 3
work that tightens management access by restricting :8080 (firewall,
network policy, mgmt_zone segregation) will leave :8443 wide open as
an equivalent attack surface — and the Phase 1 docs give the team
no reason to know it exists. Hardening controls on the OpenPLC
management UI must treat 8080 + 8443 as one logical surface, or the
second port must be documented and explicitly disabled. The generic
pattern — *documented port set ≠ actually-listening port set* — is
worth a fresh port-scan sanity check at the start of any Phase 3
hardening pass, not just for OpenPLC.

### 4. Modbus has no access control across all 8 FCs; out-of-map reads return silent zeros, not exceptions (2026-05-22)

**Source:** Scenario 2 — `docs/phase2/scenarios/scenario-2-modbus-fc-scan.md`.

**Summary:** All eight standard Modbus function codes (FC 1, 2, 3, 4,
5, 6, 15, 16) accepted by OpenPLC v3 with no exception. Reads at
unmapped addresses (HR 100, HR 1000, coil 100) returned silent
zeros — **NOT** Modbus exception 02 (Illegal Data Address) as ICS
hardening guidance leads one to expect. Out-of-map writes also
accepted (no .st variable backs those addresses, so PLC behavior is
unchanged).

**Implication:** Directly changes the Suricata rule design for
`docs/monitoring.md` §5 row 6 ("Reads outside the map"). The
detection signal CANNOT be Modbus exception responses — exceptions
never fire here. Suricata must parse address fields out of the
Modbus PDU and compare against the documented map. This is the
single most actionable Phase 2 finding for the Suricata work in
step 3.

### 5. §5.3 reassertion property extended to all output Modbus objects across all four write FCs (2026-05-22)

**Source:** Scenarios 3, 4, 4b together —
`docs/phase2/scenarios/scenario-3-coil-writes.md`,
`scenario-4-hr-writes.md`, `scenario-4b-fc15-coils.md`.

**Summary:** Phase 1 `docs/network-security.md` §5.3 documented the
reassertion-every-scan property for HR 0 only and explicitly
deferred coil writes and FC 15/16 + HR 1/HR 2 to Phase 2. All four
output write FCs (FC 5, FC 6, FC 15, FC 16) now empirically tested
against all mapped coils (0, 1, 2) and holding registers (1, 2).
Architectural property is identical in every case: write accepted at
the protocol layer, PLC overwrites within ≤1 scan (~100 ms). The
.st program's internal `SP_Low` / `SP_High` constants — which drive
the control loop — are NOT Modbus-mapped and remain unreachable from
any network peer. The original task hypothesis "could redirect pump
behavior" is empirically refuted.

**Implication:** §5.3 scope-honesty note is closed. Phase 1's
refined-framing claim — "attacker on `ot_zone` can observe
everything and can falsify the HMI's view while actively writing,
but cannot redirect the PLC's control decisions" — now has full
empirical backing.

### 6. Operational deception confirmed visually on the FUXA HMI (2026-05-22)

**Source:** Scenario 3 — `docs/phase2/scenarios/scenario-3-coil-writes.md`;
screenshot at `docs/img/phase2-scenario-3-alarm-write.png`.

**Summary:** During a 3-second FC 5 burst writing TRUE to the alarm
coil, FUXA's HMI rendered the falsified state visibly — tank at 72 %
with the Alarm indicator ACTIVE (red), well below the 90 % alarm
threshold. FUXA's ~1 Hz polling caught a between-scan window where
the attacker's write was the most recent value. An operator
monitoring this HMI would respond to a phantom alarm — the attack
creates real-world impact (investigation, possible process halt,
loss of trust in indicator) without changing actual plant behavior.

**Implication:** The detection signal at this layer must be
**source IP + FC**, not state. A rule that watches the coil's
*value* will see legitimate alarm activations and cannot distinguish
them from this attack. `docs/monitoring.md` §5 row 2 (new source IP
to :502) is the right primitive. Scenario 4's HR-write equivalent is
the same class but not visually demonstrated because the current HMI
does not display SP_Low / SP_High (tracked in Open Items as HMI
polish).

### 7. Modbus has no authentication and no integrity protection (2026-05-22)

**Source:** Scenario 5 — `docs/phase2/scenarios/scenario-5-modbus-replay.md`.

**Summary:** Two independent demonstrations from one captured PDU.
**(1) No authentication:** verbatim replay of a captured FUXA poll
(TID 0x00a3) from the attacker's source IP produced a normal PLC
response with the original TID echoed — the PLC cannot distinguish
the replay from a legitimate request. **(2) No integrity:** a
three-byte mutation of the same captured PDU (FC 3 → FC 6, address
and value bytes reinterpreted) turned a read into a write to HR 1;
the PLC accepted the mutated request and acknowledged the write.
The §5.3 reassertion wall still applied — the falsified value was
overwritten within ~1 scan.

**Implication:** Strengthens the §6 detection conclusion — payload
content (TID, FC, address, value) is freely mutable on the wire, so
no payload-content-based Suricata signal can distinguish attacker
traffic from a clever replay. Source IP + FC is the only signal
that works. Defense at the protocol layer is therefore
**segmentation + behavioral detection**, not Modbus hardening
(which the protocol does not support).

### 8. Suricata rate-threshold rules are inherently non-deterministic under multi-threaded evaluation (2026-05-23)

**Source:** Phase 2 sub-session 3a (Suricata recon detection) —
`docs/phase2/detection/3a-recon-detection.md`. Evidence preserved at
`suricata/logs/replay-3a-verify-3/eve.json` (gitignored; local-only).

**Summary:** Suricata's threshold-mode rules (`threshold: type both, track
by_src, count N, seconds W`) produce non-deterministic alert counts when
running over the same input pcap under multi-threaded evaluation. SID
9000002 (TCP SYN scan rate threshold, `count 10, seconds 10`) was replayed
five times against the same scenario-1 pcap with no rule changes:

| Run | 9000002 alerts | 9000002 timestamps |
|---|---|---|
| baseline (b7d9661) | 3 | 18:04:54.946 · 18:05:22.045 · 18:05:33.102 |
| verify (run 1)     | 2 | 18:05:45.276 · 18:06:05.317 |
| verify-2 (run 2)   | 3 | 18:04:54.872 · 18:05:33.100 · 18:06:10.387 |
| verify-3 (run 3)   | 3 | 18:04:54.522 · 18:05:24.903 · 18:05:24.875 |
| verify-4 (run 4)   | 2 | 18:04:54.523 · 18:05:17.372 |

Counts oscillate 3, 2, 3, 3, 2 (3/5 fire three alerts; 2/5 fire two).
**Timestamps shift across runs even when the count matches the baseline**
— same input, same rules, but different trigger points each time.

**Smoking-gun evidence within a single run:** run 3 fires 9000002 at
`18:05:24.903909` and `18:05:24.875207` — **28 milliseconds apart**, both
from the same source IP, both within the 10-second `track by_src`
suppression window the rule's `type both` mode is supposed to enforce.
Two alerts firing 28 ms apart from the same source proves Suricata's
threshold-suppression state machine has a race condition under
multi-threaded evaluation. The engine reports
`Threads created -> RX: 1 W: 12 FM: 1 FR: 1` — 12 worker threads racing
on the shared threshold state.

**ICS-detection-design implication:** rate-threshold rules are not
suitable as a sole detection signal where exact-count semantics matter
(compliance reporting, forensic reconstruction, alert-dedup contracts).
Cumulative flow tracking — counting unique destinations per source over
a long window, without sub-second window arithmetic — is the more robust
primitive for the same indicator class. It doesn't depend on per-thread
state synchronization and doesn't suffer window-edge jitter.

**Forward link:** sub-session 3b/3c will redesign port-scan and
connection-churn detection around flow-based primitives instead of rate
thresholds. Cross-referenced in `docs/phase2/detection/3a-recon-detection.md`
SID 9000002 discussion.

### 9. Suricata 8.0.5 modbus keyword has multiple silent comparator bugs; range form is the only reliable address filter (2026-05-24)

**Source:** Phase 2 sub-session 3b (Suricata Modbus protocol detection) —
`docs/phase2/detection/3b-modbus-protocol.md` (shipped 5e06861). Six
empirical keyword findings + two harness findings from four investigation
cycles characterizing actual vs. documented behavior.

**Summary:** Suricata 8.0.5's `modbus:` rule keyword has working primitives
(`function N`, `access read|write <table>`) and broken comparator forms.
Characterized across all 6 rules in the 3b ruleset (SIDs 9000010–9000015)
plus syntax variations on scenario-2's pcap.

**Six keyword findings (headline only — full investigation in 3b evidence doc):**

| # | Keyword form | Behavior |
|---|---|---|
| K§1 | `function N` (exact FC match) | Works as documented |
| K§2 | `access read\|write <table>` (FC class match) | Works as documented |
| K§3 | `address <N` / `address >N` on `access read` rules | **Silently no-op** — clause parses but doesn't filter; rule fires regardless of address |
| K§4 | `address <N` on `access write` rules | **Silently off-by-one** — `<3` matches addresses 0 and 1 only; address 2 silently excluded (would have missed scenario 3's alarm-coil attack) |
| K§5 | `address X<>Y` (range, exclusive) | Works AND has richer semantic than expected — matches if ANY address in the read range falls within [X,Y], not just the start address |
| K§6 | `address N` (exact match, N=0) | Produces zero matches; unverified for N≠0 |

**Two harness findings:**

| # | Issue | Workaround |
|---|---|---|
| H§1 | In-container `tcpdump -i any` pcaps have empty TCP checksums (kernel offload); Suricata's default pcap-file mode rejects them from app-layer inspection | Per-run `-k none` flag for offline replay; keeps daemon defaults intact |
| H§2 | Mid-stream baseline pcaps (no TCP handshake captured) block app-layer parser engagement entirely — `flow:established` doesn't match, parser never sees reassembled bytes | Recapture from a fresh handshake (restart FUXA so its long-lived conn re-establishes mid-tcpdump); held item |

**Detection-design implications:**

- Comparator forms (`>N`, `<N`) on read OR write rules cannot be trusted in 8.0.5. The 3b ruleset uses range form on reads (`address 3<>65535` for out-of-map detection) and drops the address sub-clause on writes (source-IP + write-class is the robust primitive — no legitimate writer exists, so any non-FUXA write is suspicious regardless of address).
- **The general lesson:** when a keyword's documented behavior diverges from its actual behavior, use the robust subset of the keyword rather than work around bugs. Source-IP + protocol-direction filters are durable across Suricata versions; address comparators are advisory until verified per-version.
- **6/6 pcap predictions matched** in the final 3b validation run (251 alerts across 4 attack pcaps, 0 on baselines). The match arrived after four iteration cycles characterizing the keyword — the investigation IS the finding, not just the clean final result.

**Forward link:** if Suricata 8.0.6+ fixes the comparator bugs (K§3, K§4), the rules as shipped might suddenly over-fire on addr=3+ writes. The 3b evidence doc Decision §2 explicitly addresses this fragility — Path R (no address sub-clause) was chosen over Path Q (off-by-one compensation `<4`) on rule-honesty + upstream-fix-robustness grounds.

### 10. FUXA 1.3.1 ModbusTCP driver has no auto-reconnect; silent client drops require detection at the deployment layer (2026-05-24)

**Source:** Mid-Phase 2 sub-session 3b investigation. Driver source:
`/usr/src/app/FUXA/server/runtime/devices/modbus/index.js` inside the
`frangoteam/fuxa:1.3.1` container.

**Summary:** When FUXA's Modbus client TCP connection drops mid-poll, the
driver logs the error and continues reading on the dead socket without
retrying. No `on-error` reconnect handler exists. Comparison with sibling
drivers in the same FUXA version: MQTT driver has `client.on("reconnect", ...)`
handler; Redis driver has `reconnectStrategy: (retries) => Math.min(100 +
retries * 200, 3000)` backoff; Modbus driver has neither. The device-config
schema does not expose a reconnect-related field because the driver
doesn't implement one.

**Observed failure mode (2026-05-24):** FUXA's HMI tank stopped rendering
in the browser. `docker compose ps` showed `otlab-fuxa` as Up. FUXA logs
showed zero Modbus error messages. `/proc/net/tcp` grep on the openplc
side showed zero ESTABLISHED conns to :502 from FUXA's IP. Recovery:
`docker compose up -d --force-recreate fuxa` re-established the connection
and the HMI resumed rendering.

**Mitigation (shipped 626fc56):** Docker healthcheck on the `fuxa` service
that probes `/proc/net/tcp` inside the FUXA container for an ESTABLISHED
conn (state 01) to openplc:502 on either bridge IP (172.18.0.2 or
172.19.0.2 in little-endian hex). After 3 consecutive 30s-interval
failures, Docker marks fuxa `(unhealthy)`. Detection-only — no autoheal
sidecar. **On unhealthy: operator runs `docker compose up -d --force-recreate fuxa`.**
End-to-end verified (stop openplc → fuxa flips unhealthy at t=93s →
restart openplc + recreate fuxa → healthy in 10s). Phase 1 attacker +
Suricata services not disturbed by the test cycle.

**Known Risk for production-equivalent deployments:** detection-only
healthcheck is sufficient for this lab's local use; production-grade
autoheal (sidecar container monitoring health-status events + auto-
restarting unhealthy containers) is a deferred follow-up for the
portfolio-prep phase post-cert. If FUXA Modbus drops become frequent
(>1/week observed), investigate environmental trigger before adding
autoheal.

---

## Phase 2 Backlog (security operations on the Phase 1 stack — documented; not built)

- [ ] **Suricata passive monitoring** — sub-sessions 3a (recon detection,
  shipped 2026-05-23) and 3b (Modbus protocol detection, shipped 2026-05-24)
  complete; sub-session 3c (replay attack detection + live-capture revisit)
  remaining. Suricata 8.0.5 multi-homed on ot_zone + mgmt_zone with pinned
  IPs (172.18.0.4 / 172.19.0.4) and Modbus app-layer parser enabled.
  11-rule ruleset total: 5 recon rules (SIDs 9000001–9000005, validated
  against scenario-1's pcap, 3/5 fired with full evidence) + 6 Modbus
  protocol rules (SIDs 9000010–9000015, 6/6 prediction match across 4
  attack pcaps and 2 baselines). Full write-ups in
  `docs/phase2/detection/3a-recon-detection.md` and
  `docs/phase2/detection/3b-modbus-protocol.md`.
- [x] **Attacker container in `attacker_zone`** (shipped 2026-05-22) — pinned Dockerfile on `debian:bookworm-20260518-slim` with nmap, tcpdump, curl, dig, ping, ip, pymodbus 3.6.9, scapy. Sits idle on `attacker_zone` only; reached via `docker exec`. Segmentation proof in [Phase 2 Findings §1](#phase-2-findings).
- [ ] Historian (InfluxDB + Grafana)
- [x] **Written-up attack scenarios** (shipped 2026-05-22) — five
  scenarios executed against the live stack from an ot_zone-attached
  attacker; six new findings logged (§2–§7 above). Per-scenario
  evidence in `docs/phase2/scenarios/*.md`; capture artifacts
  gitignored in `captures/`. Operational follow-up: add `procps` to
  `plc/Dockerfile` and `attacker/Dockerfile` so `pkill` is available
  without runtime install (currently installed at runtime per
  `docs/monitoring.md` §3 Method B; baked-in install removes the
  container-recreation loss step).
- [ ] Real network diagram with assigned IPs

---

## Phase 3 Backlog (platform migration and zone hardening — documented; not built)

- [ ] Tighten `mgmt_zone` ↔ `ot_zone` into a hard boundary (currently soft)
- [ ] Migrate OpenPLC v3 → v4 (see spike findings 2026-05-21). v3 is upstream
      EOL, and disaster recovery on 2026-05-21 is direct evidence — v4's
      architecture may eliminate this class of state-drift brittleness. The
      same-day verification spike confirmed v4 is fundamentally different
      from v3: no web UI (REST API on port 8443 only, by design), Modbus
      is an add-on plugin (`modbus_slave`) that loads at container start
      but does not begin listening on port 502 until the PLC enters RUNNING
      state, and the PLC cannot reach RUNNING without a compiled program
      uploaded via the REST API (any HTTP client can drive that upload).
      Migration is its own dedicated phase, not a drop-in image swap —
      Phase 3 will need the REST-driven program upload workflow figured
      out before v3-equivalent functionality is back online.

---

## Environment Prerequisite (MANUAL)

- Docker Desktop on Windows with **WSL2 integration enabled** for this distro.
  *(Status 2026-05-21: Docker Desktop installed, WSL2 integration confirmed.
  Lab proven running end-to-end — OpenPLC built from pinned source, ST
  compiled clean, PLC Running, live Modbus/TCP on :502 verified via pymodbus,
  FUXA connected with HMI animating, Wireshark baseline capture landed.
  Phase 1 Acceptance Gate fully met.)*
