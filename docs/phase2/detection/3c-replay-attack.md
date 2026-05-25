# Phase 2 Step 3c — Replay-Attack Detection (Suricata Sub-session 3 of 3)

**Status:** Shipped 2026-05-25. Offline-only validation. Live-capture
deferred — see Architectural Decisions §1.

This sub-session is the third and final piece of Phase 2 step 3
(Suricata IDS). 3a shipped 5 recon rules; 3b shipped 6 Modbus
protocol-aware rules. 3c covers the replay attack scenario (Phase 2
scenario 5 — `docs/phase2/scenarios/scenario-5-modbus-replay.md`) and
revisits the question of live-capture deployment that 3a and 3b both
deferred.

The honest finding for 3c is mostly negative:

1. Modbus has no authentication or integrity, so a clever attacker can
   byte-match legitimate FUXA traffic except for source IP. Source IP
   is the only protocol-layer signal that distinguishes them. The
   actual control for replay is network segmentation, not signatures.
2. The pre-3c ruleset (11 SIDs) already detects scenario 5 fully:
   9000003 catches the three attacker TCP handshakes at L4, and
   9000013 catches the mutated FC 6 write at the Modbus layer.
3. Two new SIDs (9000020, 9000021) ship in 3c as forensic-granularity
   companions to 9000012 / 9000013 — they add app-layer evidence
   (`app_proto: modbus` + read operation) to the existing L4 alerts,
   not new detection capability.
4. Live-capture deployment was evaluated and deferred. Docker Desktop
   on Windows runs containers in the Moby VM; its `network_mode: host`
   is layer-4 only and does not give containers AF_PACKET access to
   the Moby VM bridge interfaces. Native Linux Docker is the path for
   live capture; documented here for after-cert portfolio work, not a
   3c-actionable item.

---

## Setup

### What changed from 3b

| Area | 3b state | 3c state |
|---|---|---|
| Ruleset | 11 SIDs (9000001–9000005, 9000010–9000015) | 13 SIDs (+9000020, +9000021) |
| Capture mode | Offline pcap replay | Offline pcap replay (unchanged) |
| Suricata compose | Bridge networks, pinned 172.18.0.4 / 172.19.0.4 | **Unchanged** |
| `suricata.yaml` | af-packet eth0/eth1 | **Unchanged** |

No `docker-compose.yml` edits, no `suricata.yaml` edits, no scenario-5
doc appendix. The only file modified in 3c's first commit is
`suricata/rules/local.rules` (+77 lines).

### Scope — offline-only validation (live capture deferred)

3a and 3b both validated against offline pcap replay because Docker
bridge MAC-learning means a passive Suricata container sees broadcasts
+ own traffic only, not unicast between other containers (3b Harness
section). The question for 3c was whether to fix this.

Outcome: deferred. Reasoning is in Architectural Decisions §1 and
Live-Capture Finding §1 below. Short version: the obvious fix
(`network_mode: host`) does not work on Docker Desktop because Docker
Desktop's host mode is layer-4 only on Windows, not raw L2 access.
Native Linux Docker is the path; not in 3c's scope.

### Sensor placement, IP pinning — continuity from 3b

No changes. Suricata stays multi-homed on `ot_zone` (172.18.0.4) and
`mgmt_zone` (172.19.0.4) via the same compose stanza shipped in 3a.

### Capture method — offline pcap replay with `-k none`

Same as 3b. Per 3b Harness Finding §1, in-container `tcpdump -i any`
produces bad-checksum pcaps that Suricata's default pcap-file mode
rejects from app-layer inspection. `-k none` disables checksum
validation. Subject pcap for 3c is
`captures/phase2-scenario-5-replay-2026-05-22.pcap` (5,671 bytes,
60 packets, captured via `tcpdump -i any` inside `otlab-openplc`).

Command used for the 3c validation run:

```bash
docker exec otlab-suricata sh -c '
  mkdir -p /var/log/suricata/replay-3c &&
  suricata -c /etc/suricata/suricata.yaml \
    -r /captures/phase2-scenario-5-replay-2026-05-22.pcap \
    -k none \
    -l /var/log/suricata/replay-3c/ \
    -v
'
```

Flags verified against `--help` (per project verifying-cli-flags
discipline): `-r`, `-l`, `-k`, `-v`, `-c` all canonical. No long-form
substitutions.

---

## Ruleset

### SIDs 9000020–9000021 added

Both new rules use the same shape as 9000012 / 9000013 (non-FUXA
writes): `!$FUXA_IP -> $OPENPLC_IP $MODBUS_PORT`,
`flow:to_server,established`, `modbus: access read <table>`, no
address sub-clause. The rationale for omitting the address sub-clause
is the same as 3b's writes — Suricata 8.0.5 address comparator
behavior on read rules is unreliable (3b Keyword Finding §3), and the
detection signal is source-IP-not-FUXA + read-class, not address.

| SID | FC | Trigger | Classtype |
|---|---|---|---|
| 9000020 | 1 (Read Coils) | from non-FUXA source | `attempted-recon` |
| 9000021 | 3 (Read Holding Registers) | from non-FUXA source | `attempted-recon` |

`attempted-recon` was chosen over `attempted-admin` because reads are
information disclosure, not control alteration; matches Snort's
`classification.config` taxonomy.

These are **NOT replay-detection rules.** They detect unauthorized
Modbus reads. Replay is one instance of unauthorized reads — the
rules will fire on the read portion of a replay attack, but they will
equally fire on any other unauthorized read (recon, data exfil,
operator monitoring from the wrong host).

### Total ruleset state (13 SIDs)

| SID range | Step | Coverage |
|---|---|---|
| 9000001–9000005 | 3a | Recon (ICMP sweep, TCP SYN scan, port-specific SYN, web UI, RST churn) |
| 9000010–9000011 | 3b | Baseline-unused FCs (FC 2, FC 4) — any source |
| 9000012–9000013 | 3b | Non-FUXA writes (coils, holding) |
| 9000014–9000015 | 3b | Out-of-map reads (coils, holding) — any source |
| 9000020–9000021 | 3c | Non-FUXA reads (coils, holding) |

### Engine warnings — diff against 3b baseline

No new warnings. Engine startup line from the 3c validation run:
"13 rules successfully loaded, 0 rules failed, 0 rules skipped" and
"13 signatures processed. 0 are IP-only rules, 0 are inspecting
packet payload, 8 inspect application layer, 0 are decoder event
only." Eight app-layer signatures matches the count of Modbus
keyword rules (9000010–9000015, 9000020, 9000021 = 8). Stable
against 3b's baseline (which had 6 app-layer signatures pre-3c).

---

## Offline replay — against scenario-5 pcap

### Summary

| SID | Alerts | Predicted | Match |
|---|---|---|---|
| 9000003 | 3 | 3 | ✓ |
| 9000013 | 1 | 1 | ✓ |
| 9000020 | 0 | 0 | ✓ (caveat — see below) |
| 9000021 | 2 | 2 | ✓ |
| **Total** | **6** | **6** | **✓** |

All four counts match prediction exactly. Total alerts = 6.

### Per-SID firing detail

#### SID 9000003 — 3 alerts (3a recon rule)

    05/22 19:08:37.967672  172.18.0.4:40050 -> 172.18.0.2:502
    05/22 19:08:38.024033  172.18.0.4:40058 -> 172.18.0.2:502
    05/22 19:08:38.124524  172.18.0.4:40068 -> 172.18.0.2:502

Three alerts, one per attacker TCP handshake (verbatim-replay flow,
mutate-and-replay flow, verify-read flow). All from 172.18.0.4
(attacker's ot_zone IP at capture time — pre-dated Suricata's
172.18.0.4 pinning) to openplc:502. `app_proto: -` in eve.json — this
is an L4 alert fired at SYN time, no Modbus parser engagement expected.

#### SID 9000013 — 1 alert (3b non-FUXA write)

    05/22 19:08:38.123760  172.18.0.4:40058 -> 172.18.0.2:502
      modbus.request.function_code = WrSingleReg (FC 6)
      modbus.request.transaction_id = 163 (0x00a3)
      modbus.request.write.address = 1, data = 4242 (0x1092)

The mutated FC 6 write. TID 163 = 0xa3 — the attacker reused FUXA's
original TID from the verbatim-replay flow. Address HR 1
(SP_Low_Out), value 4242. Suricata's modbus parser fully decoded the
PDU. The PLC accepted the write (RSP visible in pcap at pkt[27]); the
scenario-5 doc records the immediate verify-read returning HR 1 = 20,
which is §5.3 reassertion in action.

#### SID 9000020 — 0 alerts (with verification caveat)

The scenario-5 pcap contains no FC 1 (read coils) PDU from a non-FUXA
source. The attacker exercised only FC 3 (read) and FC 6 (write).
9000020 had nothing to match.

**Verification caveat:** 9000020 has not been positively exercised in
any 3c artifact. We cannot distinguish "9000020 correctly didn't fire
because attacker emitted no FC 1" from "9000020 has a latent bug that
would prevent firing on FC 1 from a non-FUXA source." By construction,
9000020 has the same shape as 9000021 (only `coils` vs `holding` in
the `access read` keyword), and 9000021 is empirically verified to
fire correctly. Per 3b Keyword Finding §1 (`function N` matches as
documented for table-based keywords), 9000020 should behave
identically to 9000021 for FC 1. But this is an inference, not a
direct verification.

A future scenario emitting FC 1 from an attacker would close this gap.
Held for that.

#### SID 9000021 — 2 alerts (3c non-FUXA read — the no-per-session-dedupe finding)

    05/22 19:08:38.023600  172.18.0.4:40050 -> 172.18.0.2:502
      modbus.request.function_code = RdHoldRegs (FC 3)
      modbus.request.transaction_id = 163 (0x00a3)  ← MATCHES FUXA'S TID
      modbus.request.read.address = 0, quantity = 3

    05/22 19:08:38.223897  172.18.0.4:40068 -> 172.18.0.2:502
      modbus.request.function_code = RdHoldRegs (FC 3)
      modbus.request.transaction_id = 66 (0x0042)   ← attacker-chosen
      modbus.request.read.address = 1, quantity = 1

Two alerts on a single attack session. The first is the verbatim
replay — TID 163 = 0xa3, reading HR 0..2, byte-identical to FUXA's
captured PDU. The second is the attacker's own verify-read with a
new TID. This is the **no-per-session-dedupe finding** (Replay
Finding §4 below): Suricata fires one alert per non-FUXA read PDU,
not one per attack session. For a multi-PDU attack (replay + verify,
or extended exfiltration), 9000021 will fire repeatedly. This is
expected Suricata signature behavior; flagging it because the alert
volume per attack is a number a downstream SIEM/SOC needs to know.

### Inherited-FP-coverage caveat

3c re-validates only the FCs that appear in the scenario-5 pcap
(FC 1 from FUXA, FC 3 from FUXA + attacker, FC 6 from attacker).
False-positive coverage for rules covering FCs NOT in this pcap is
inherited from 3b, not re-validated by 3c:

- 9000010 (FC 2 any source) — 3b validated
- 9000011 (FC 4 any source) — 3b validated
- 9000012 (FC 5 / 15 non-FUXA) — 3b validated
- 9000014 (FC 1 out-of-map any source) — 3b validated

3c does not stand in for "0 FPs across the full 13-rule ruleset." The
honest claim is: 3c offline-replay of scenario-5 produced exactly the
6 expected alerts and no others. Broader FP coverage relies on 3b's
prior work plus a future fresh-baseline-pcap recapture (held item).

The mid-stream-handshake limitation from 3b Harness Finding §2 also
applies here — FUXA's flows in the scenario-5 pcap are mid-stream
(no SYN in capture). FUXA PDUs would not exercise 9000020 / 9000021
even if they were going to the wrong addresses, because the app-layer
parser does not engage on mid-stream flows. The PLC-side rules that
do engage are the ones on the attacker's three fresh-handshake flows.

---

## Findings

### Replay Finding §1 — Modbus has no authentication or integrity; source IP is the only protocol-layer signal

Scenario 5 proved empirically (and at the pcap byte level) that:

- The attacker sent a byte-for-byte copy of FUXA's captured FC 3
  read PDU (TID 0x00a3, addr 0, qty 3) from a different source IP
  on a different network segment. The PLC processed it as a legitimate
  request and returned current tank-fill data.
- The attacker then flipped 3 bytes of the captured PDU (FC 0x03 →
  0x06, addr 0x0000 → 0x0001, value tail bytes → 0x1092) and the PLC
  accepted it as a fresh FC 6 write to HR 1.

There is no nonce, no sequence number, no per-connection state the
PLC compares against, no MAC, no checksum that catches this. The
ONLY signal at the Modbus protocol layer that distinguishes the
attacker's PDU from FUXA's is the IP source address in the TCP/IP
header below the Modbus PDU.

Implication for IDS rule design: any rule that aspires to detect
replay attacks at the Modbus layer is, in practice, a
source-IP-filter rule (with optional protocol-layer context). The
rule has no other signal to rely on.

### Replay Finding §2 — pre-3c rules already detect scenario 5

The 11 SIDs shipped in 3a + 3b already produced 4 alerts against
scenario 5 (9000003 ×3 + 9000013 ×1) before 3c. The new SIDs 9000020
+ 9000021 add 2 more alerts (forensic granularity on the read PDUs)
but do not change the answer to "did Suricata detect this attack."
The answer was yes pre-3c.

The 3c contribution is alert *richness*, not detection *coverage*.

### Replay Finding §3 — segmentation is the actual control

If the attacker had been unable to reach `ot_zone` (Phase 1 §4 plus
Phase 2 step 1's enforcement boundary), none of the scenario-5 PDUs
would have been emitted, and no IDS rule would have needed to fire.
Detection at the IDS layer is a backstop, not the primary defense.

3c's rules operationalize "non-FUXA at the PLC is anomalous" — they
do not, and cannot, distinguish a clever replay from a fresh attack.
A defender relying on signature inspection alone, with no
segmentation, has no defense against an attacker who matches FUXA's
TID + FC + address + value.

### Replay Finding §4 — 9000021 fires twice per attack session (no per-session dedupe)

In scenario 5 the attacker emits two FC 3 reads from a non-FUXA
source — one verbatim replay (TID 0x00a3) and one verify-read (TID
0x0042). Suricata fires 9000021 twice, once per PDU.

This is expected Suricata signature behavior (no per-session
deduplication), not a rule defect. Documented here because for a
downstream SIEM or SOC, the alert volume per attack session matters:
a multi-PDU read exfiltration would produce one 9000021 alert per
PDU, not one alert per session.

If alert volume becomes a triage burden in a real deployment,
candidates: `threshold: type limit, track by_src, count 1, seconds 60`
on 9000020 / 9000021 to dedupe to one alert per source per minute.
Not applied in 3c — for a lab with low traffic and a learning
context, the per-PDU granularity is the more useful signal.

### Live-Capture Finding §1 — Docker Desktop's `network_mode: host` is layer-4 only

Initial 3c plan considered `network_mode: host` for Suricata to
enable live AF_PACKET capture on the lab's docker bridge interfaces
(`br-*` in the Moby VM). Reading the Docker documentation pre-build
caught a critical platform constraint:

> "The host network feature of Docker Desktop works on layer 4. This
> means that unlike with Docker on Linux, network protocols that
> operate below TCP or UDP are not supported. Processes inside the
> container cannot bind to the IP addresses of the host because the
> container has no direct access to the interfaces of the host."
> — https://docs.docker.com/engine/network/drivers/host/

Suricata's af-packet capture is L2; it requires raw interface access.
Docker Desktop's host mode does not provide this. The br-* interfaces
visible from a privileged probe into the Moby VM are not accessible
to a host-mode Suricata container for AF_PACKET capture — different
mechanisms.

Live-capture deployment requires native Linux Docker as the underlying
platform (e.g., `docker-ce` installed directly inside WSL2, or a
dedicated Linux host running the lab). Once on native Linux Docker,
three capture strategies become viable:

- `network_mode: host` for Suricata — real AF_PACKET access to br-*
  bridges. Simplest. Recommended path for a future native-Linux
  migration.
- macvlan driver swap — Suricata gets a unique MAC at the physical
  layer, but invasive compose rewrite and ties the lab to a specific
  host NIC name. Not recommended.
- iptables NFLOG mirroring on the host — works but adds host-kernel
  state coupling and brittleness. Not recommended.

None of the three options work on Docker Desktop on Windows / macOS —
the Moby VM netns is not accessible to host-mode containers via the
documented Docker Desktop API.

All three options are out of scope for 3c. Documented as a deferred
item for post-cert portfolio-prep work. The cert curriculum doesn't
depend on live capture; offline pcap replay is sufficient for Phase 2's
demonstration.

---

## Architectural Decisions

### Decision §1 — Live capture deferred (Docker Desktop platform constraint)

**Decision:** 3c ships with offline pcap replay only. No
`docker-compose.yml` or `suricata.yaml` modifications.

**Alternatives evaluated and dismissed:**

- `network_mode: host` for Suricata — does not work on Docker Desktop
  (Live-Capture Finding §1).
- macvlan driver swap — invasive compose rewrite, ties lab to host NIC
  name, overkill for a 4-container lab.
- iptables NFLOG mirroring on host — couples lab to host kernel
  iptables state, brittle.
- Sidecar `network_mode: container:openplc` — only sees one
  container's vantage, loses dual-homed mgmt + ot view.

**Path forward:** native Linux Docker deployment is documented as a
post-cert portfolio-prep item. Not a 3c blocker.

### Decision §2 — Scope of replay-detection rules: forensic granularity, not new detection

**Decision:** 9000020 and 9000021 ship as forensic-uplift rules that
add `app_proto: modbus` evidence to existing L4 alerts. They do not
add new detection coverage beyond what 9000003 already provides.

**Reasoning:** every flow that fires 9000020 or 9000021 also fires
9000003 at the SYN. The pre-3c ruleset already detected scenario 5
fully (Replay Finding §2). The forensic value of the new rules is in
the alert payload — the analyst gets the Modbus operation type and
PDU detail, not just "L4 contact."

**Alternative considered:** ship zero new SIDs in 3c. Rejected because
the source-IP-filtered by-table matrix would have been asymmetric —
writes had 9000012 / 9000013, reads only had the out-of-map rules
9000014 / 9000015 with no source-IP filter. The two new SIDs complete
the matrix.

### Decision §3 — What is intentionally not detected at the Modbus layer

The following signals were considered for Modbus-layer detection rules
in 3c and explicitly excluded:

- **TID reuse across source IPs / connections.** Suricata's modbus
  keyword does not expose TID for cross-flow comparison, and FUXA
  itself cycles TIDs 0x0000–0xFFFF during normal polling. Any "same
  TID seen recently" rule would false-positive against legitimate
  FUXA traffic.
- **Payload-hash repetition (true replay-of-FUXA-PDU signal).** Would
  catch the verbatim replay specifically. Not expressible as a stock
  Suricata signature — would require stateful cross-flow correlation
  (a SIEM/correlation engine, not an IDS).
- **Address-aware filtering on the new read rules.** Suricata 8.0.5
  modbus keyword's address comparators are buggy on read rules (3b
  Keyword Finding §3); only the X<>Y range form works. The detection
  signal is source-IP + read-class, not address — adding an address
  filter would narrow detection without adding value.

These are flagged so future-you doesn't propose them again under the
assumption that they'd add detection. They wouldn't.

---

## Cross-references

### Resolved (exist on disk at 3c ship time)

- `suricata/rules/local.rules` — 13 SIDs total after 3c
- `captures/phase2-scenario-5-replay-2026-05-22.pcap` — 5,671 bytes,
  60 packets (gitignored)
- `docs/phase2/scenarios/scenario-5-modbus-replay.md` — the attack
  description and PDU byte-level decode
- `docs/phase2/detection/3a-recon-detection.md` — sibling sub-session 1
- `docs/phase2/detection/3b-modbus-protocol.md` — sibling sub-session 2

### Forward references — FORWARD until resolved this session

- `docs/MASTER.md` Phase 2 Findings section — to be updated in
  Change 3 of this session with 3c additions (Replay Findings §1–§4,
  Live-Capture Finding §1).
- `suricata/rules/local.rules` — 9000020 + 9000021 currently carry
  FORWARD-labeled comments referencing this evidence doc and MASTER.md.
  A rev:2 bump strips those labels in Change 4 of this session
  ("loop closed" commit).

### Held items (deferred work, NOT 3c blockers)

- Fresh clean baseline pcap recapture (carried over from 3b held items)
  — needed for direct FP validation of the full 13-rule set against a
  handshake-present baseline. The mid-stream FUXA flows in scenario-5
  pcap don't fully exercise it.
- Live-capture deployment on native Linux Docker — post-cert
  portfolio-prep work (Live-Capture Finding §1).
- Positive verification of 9000020 (a future scenario emitting FC 1
  from a non-FUXA source would close the inference gap in §SID 9000020
  above).

---

## Authoring discipline self-check

- All file paths referenced above were grep-verified against the repo
  prior to commit. The 3c evidence doc, 3a doc, 3b doc, scenario-5
  doc, local.rules, and scenario-5 pcap all exist on disk verbatim.
- The MASTER.md update referenced is a FORWARD reference at the time
  of this doc's commit; lands in Change 3 of this session.
- The rev:2 strip of FORWARD labels on 9000020 + 9000021 in
  `local.rules` is also a FORWARD reference at this doc's commit time;
  lands in Change 4 of this session.
- All Suricata CLI flags used in the validation run (`-r`, `-l`,
  `-k`, `-v`, `-c`) verified against `suricata --help` before
  invocation (project verifying-cli-flags discipline).
- All runtime claims (alert counts, eve.json field values, ruleset
  state, container state) verified against the live Suricata replay
  run, not against prior docs. Replay output retained at
  `suricata/logs/replay-3c/` (gitignored) for future reference.
