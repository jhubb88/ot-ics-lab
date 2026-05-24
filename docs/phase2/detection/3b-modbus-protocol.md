# Phase 2 Step 3b — Modbus Protocol Detection (Suricata Sub-session 2 of 3)

**Date:** 2026-05-24
**Source task:** Phase 2 step 3 (Suricata passive monitoring), sub-session 3b — Modbus protocol-aware ruleset.
**Subject pcaps:** 4 attack (scenarios 2/3/4/4b) + 2 baseline (Phase 1 + Phase 2).
**Result:** 6/6 pcap counts match prediction exactly (251 alerts on 4 attack pcaps, 0 on 2 baselines). The match arrived AFTER four iteration cycles on the Suricata 8.0.5 modbus keyword to characterize its actual behavior vs. its documented behavior — the investigation produced the centerpiece findings, not just the final clean result.

---

## Setup

### What changed from 3a

3a established the Suricata service: container deployment, pinned IPs (openplc + fuxa), IDS mode, sensor placement on both `ot_zone` + `mgmt_zone`. 3b is additive — no compose / container / network changes. Two file changes:

1. `suricata/suricata.yaml` — enable the Modbus app-layer parser.
2. `suricata/rules/local.rules` — append 6 protocol-aware rules (SIDs 9000010–9000015), preserving 3a's 5 recon rules byte-identical.

Suricata recreate (single service) is sufficient; Phase 1 services (openplc, fuxa, attacker) preserved throughout.

### Modbus app-layer parser enable

Block added under `app-layer.protocols` in `suricata.yaml`:

    modbus:
      enabled: yes
      detection-ports:
        dp: 502
      stream-depth: 0

Replaced the deferral comment from 3a (`# Modbus parser stays at upstream default (off). Sub-session 3b will enable it for protocol-aware rules.`). `stream-depth: 0` = unlimited reassembly per upstream Modbus Messaging on TCP/IP guide V1.0b (Modbus connections are long-lived; capping reassembly would drop tail PDUs). `request-flood` flood-detection sub-option left commented out — rate thresholds are non-deterministic under multi-threaded eval (Finding §8 from MASTER.md). Memory post-enable: 67 MiB at idle, unchanged from 3a baseline (modbus parser adds negligible per-flow state at idle).

### Sensor placement, IP pinning — continuity from 3a

Unchanged. Suricata still multi-homed on both networks at 172.18.0.4 / 172.19.0.4 (Docker-assigned next-free slots; explicit pinning still on the post-3a follow-up queue). $FUXA_IP, $OPENPLC_IP, $MGMT_OPERATOR variables in `suricata.yaml` continue to resolve to the pinned bridges from 3a.

### Capture method — offline pcap replay with `-k none`

Same offline-replay approach as 3a, with one critical flag addition: **`-k none`**.

The 4 attack pcaps from Phase 2 step 2 were captured via `tcpdump -i any` **inside the openplc container**, which sees outbound packets BEFORE the NIC computes TCP checksums (kernel relies on checksum offload). The resulting pcap files have empty/invalid TCP checksums on outbound packets. Suricata's default pcap-file mode rejects bad-checksum packets from app-layer inspection — TCP-layer matches still work (which is why 3a's L4 rules fired on these pcaps just fine), but the modbus parser never sees reassembled PDUs.

Symptom: scenario-2 replay against the freshly-built ruleset fired ONLY 9000003 (3a's TCP SYN rule) on its first run. Zero modbus alerts despite valid attack PDUs visible in the pcap. The Suricata startup warning explicitly hinted at the fix:

    Warning: pcap: 1/1th of packets have an invalid checksum, consider setting
    pcap-file.checksum-checks variable to no or use '-k none' option on command line.

`-k none` (per-run flag) chosen over editing `pcap-file.checksum-checks: no` in yaml — keeps daemon's default checksum-validation behavior intact for live-capture later, only the offline replay sessions need the override. This is **Harness Finding §1** (detailed in Findings section).

Replay command for all 6 pcaps:

    docker exec otlab-suricata suricata \
      -r /captures/<pcap-filename> \
      -c /etc/suricata/suricata.yaml \
      -l /var/log/suricata/replay-3b-<scenario> -v -k none

Output isolated under `suricata/logs/replay-3b-<scenario>/` per pcap (six directories, one per pcap). All gitignored under `suricata/logs/*`.

---

## Ruleset

Six rules in `suricata/rules/local.rules`. SID range 9000010–9000015 (gap 9000006–9000009 reserved for 3a follow-ups; 9000020+ reserved for 3c).

| SID | Rev | Detection | monitoring.md §5 row |
|---|---|---|---|
| 9000010 | 1 | Modbus FC 2 (Read Discrete Inputs) — any source | baseline-violation (FC 2 has zero legitimate use; not §5 explicitly) |
| 9000011 | 1 | Modbus FC 4 (Read Input Registers) — any source | baseline-violation (FC 4 has zero legitimate use) |
| 9000012 | 3 | Modbus write to coils (FC 5/15) — non-FUXA source | row 1 (any write FC) + row 2 (new source IP to :502) |
| 9000013 | 3 | Modbus write to holding registers (FC 6/16) — non-FUXA source | row 1 + row 2 |
| 9000014 | 2 | Modbus FC 1 read where range overlaps coils ≥ 3 | row 6 (reads outside the map) |
| 9000015 | 2 | Modbus FC 3 read where range overlaps HR ≥ 3 | row 6 |

Map cutoff for 9000014/9000015 verified against `plc/tank_fill.st` lines 21–27 (MODBUS MAP comment) and lines 42–47 (AT-located variable declarations):

- Coils 0,1,2 = Pump_Run, Valve_Open, High_Alarm
- HR 0,1,2 = Level_PV, SP_Low_Out, SP_High_Out
- Out-of-map = address ≥ 3

Write rules (9000012/9000013) deliberately have NO address sub-clause — that is the result of the investigation below, not an oversight. Read rules use the range form `address 3<>65535` rather than the comparator form `address >2` — also a result of the investigation. The reasoning for both choices is in **Architectural Decisions** below.

### Engine warnings — pre-existing only, no new

Suricata startup logs only the same three warnings 3a saw:

    Warning: no sys_nice capability, use --cap-add sys_nice
    Warning: running as root due to missing capabilities
    W: counters: global stats config is missing. Stats enabled through legacy stats.log.

Zero new warnings from the 3b ruleset additions. The 3a-era rule-load warnings about SIDs 9000003 / 9000004 ("SYN-only to port(s) w/o direction specified") were silenced earlier in this session by adding `flow:not_established,to_server;` to those rules — confirmed clean in this run.

`suricata -T -v` confirms post-load:

    11 rules successfully loaded, 0 rules failed, 0 rules skipped
    6 inspect application layer    ← all 6 modbus rules engage the parser

---

## Offline replay — summary

All 6 pcaps replayed cleanly with `-k none`. Every observed count matched its prediction exactly.

| pcap | packets | 3b alerts | predicted | ✓/✗ |
|---|---|---|---|---|
| `phase2-scenario-2-fc-scan-2026-05-22.pcap` | 60 | 10 | 10 | ✓ |
| `phase2-scenario-3-coil-writes-2026-05-22.pcap` | 279 | 60 | 60 | ✓ |
| `phase2-scenario-4-hr-writes-2026-05-22.pcap` | 464 | 121 | 121 | ✓ |
| `phase2-scenario-4b-fc15-coils-2026-05-22.pcap` | 288 | 60 | 60 | ✓ |
| `phase2-baseline-clean-2026-05-22.pcap` | 180 | 0 | 0 (with caveat — see Baseline section) | ✓ |
| `modbus-baseline-20260520.pcap` | 2502 | 0 | 0 (same caveat) | ✓ |

3a's SID 9000003 (TCP SYN to :502 from non-FUXA) fires once on each attack pcap — expected continuity, not counted in 3b totals.

### Per-pcap detail

#### scenario-2 (10 alerts)

    1× 9000010   FC 2 Read Discrete Inputs (baseline-unused FC)
    1× 9000011   FC 4 Read Input Registers (baseline-unused FC)
    2× 9000012   FC 5 + FC 15 writes to coil 5 (unmapped — protocol-surface enum)
    2× 9000013   FC 6 + FC 16 writes to HR 5 (unmapped)
    2× 9000014   FC 1 reads where range touches out-of-map
    2× 9000015   FC 3 reads where range touches out-of-map

The 9000014 alerts fired on:
- `RdCoils addr=0 qty=6` (covers coils 0..5 — crosses the in-map boundary, includes unmapped 3,4,5)
- `RdCoils addr=100 qty=8` (fully out-of-map)

The FC 1 read at `addr=0 qty=3` (covers coils 0..2, fully in-map) was correctly EXCLUDED. The range-form keyword's "any-addr-in-read-range" semantic catches boundary-crossing reads as well as fully-OOM reads — a richer detection signal than start-address-only matching would give.

The 9000015 alerts fired on `RdHoldRegs addr=100 qty=5` and `RdHoldRegs addr=1000 qty=1`. The FC 3 read at `addr=0 qty=3` was correctly EXCLUDED. Same range-form semantic as 9000014.

#### scenario-3 (60 alerts)

    60× 9000012   FC 5 write_coil(addr=2) — alarm coil falsification

All 60 alerts have identical structure: `WrSingleCoil addr=2`. This is the operational-deception attack from MASTER.md Finding §6 (HMI rendering tank=72% + Alarm ACTIVE during a normal fill cycle). Every burst write fired.

**Critical:** an earlier rule design (`address <3` comparator form) silently MISSED these 60 alerts. The `<N` comparator on `access write` rules is off-by-one in Suricata 8.0.5 — it interprets `<3` as `<(3-1) = <2`, matching only addresses 0 and 1. Coil 2 (the alarm coil) was silently excluded. The investigation that found this is Keyword Finding §4 below; the rule that ships dropped the address sub-clause entirely (Architectural Decision §2).

#### scenario-4 (121 alerts)

    60× 9000013   FC 6 write_register(addr=1) — SP_Low_Out falsification
    60× 9000013   FC 6 write_register(addr=2) — SP_High_Out falsification
     1× 9000013   FC 16 write_registers(addr=1, qty=2) — bonus multi-register write

121 = 60 + 60 + 1 matches the scenario-4 attack script (60 FC 6 to HR 1 alternating with 60 FC 6 to HR 2 in the burst, plus one bonus FC 16 covering HR 1+2).

The earlier `<3` rule fired only on addr=1 (60 + 1 = 61), silently missing the 60 addr=2 writes. Same off-by-one bug as scenario-3.

#### scenario-4b (60 alerts)

    60× 9000012   FC 15 write_coils(addr=0, qty=3) — Pump+Valve+Alarm falsification

All 60 FC 15 PDUs caught. The `<3` rule happened to fire correctly on this scenario because start_addr=0 (within both the intended `<3` and the buggy `<2` interpretation). Scenario-4b alone wouldn't have surfaced the bug.

#### Baseline traffic validation (with explicit caveat)

Both baseline pcaps fired ZERO alerts on all 6 3b SIDs:

- `phase2-baseline-clean-2026-05-22.pcap` (17 KB, post-pinning, state-matched): 0 alerts
- `modbus-baseline-20260520.pcap` (240 KB, Phase 1 baseline, pre-pinning): 0 alerts

**However, this is not a clean false-positive check.** Both baseline pcaps were captured mid-stream — they start with a TCP PSH+ACK packet (already-established FUXA→openplc connection), not a SYN. Suricata's TCP stream reassembly requires seeing the 3-way handshake to track stream state. Without the handshake:

- `flow:to_server,established` clauses don't match (no established state tracked)
- App-layer protocol detection doesn't run (needs valid reassembled stream)
- The modbus parser never engages on these pcaps

`app_proto: "-"` on the baseline flow records and `modbus: 0` in `app_layer.flow` stats confirm the parser saw zero modbus traffic. The 0-alert result therefore tells us **nothing about whether the rules would fire on legitimate FUXA polling** — only that the rules don't fire on TCP-layer-only traffic, which we'd expect.

A proper FP check requires recapturing baseline traffic from the TCP handshake start (e.g., by restarting FUXA so the Modbus connection re-establishes during capture). This is **Harness Finding §2** and is tracked as a held item: recapture follow-up after 3b ships. For 3b, the false-positive risk is bounded by reasoning rather than empirical test:

- 9000010/9000011 (FC 2 / FC 4): baseline uses only FC 1 + FC 3, so these can't fire on legitimate poll PDUs.
- 9000012/9000013 (writes from `!$FUXA_IP`): baseline source IS FUXA, so the source-IP filter excludes baseline traffic by construction.
- 9000014/9000015 (reads with range overlap ≥ 3): baseline FUXA polls read addrs 0..2 only (per `plc/tank_fill.st` map), so the range `3<>65535` cannot overlap a legitimate poll. Validated against scenario-2's `RdHoldRegs addr=0 qty=3` PDU which the rule correctly EXCLUDED (same in-map read shape as baseline FUXA's polls).

Confidence that these rules don't false-positive on legitimate FUXA polling is **High by reasoning, Medium by empirical test** (the test is blocked by Harness Finding §2).

---

## Investigation iteration — four cycles to characterize the keyword

The 6/6 clean result above is the endpoint of four investigation cycles. Compressed timeline:

**Cycle 1 — Naive first ruleset, all six rules use comparator forms.**
Read rules: `modbus: access read coils/holding, address >2`. Write rules: `address <3` from `!$FUXA_IP`. Replay against scenario-2: ZERO modbus alerts on first run. Hypothesis: checksum-validation. Re-ran with `-k none`: now 9000014 fires 2× and 9000015 fires 3× — but on PDUs with `start_addr=0`. That can't be right under `>2` semantics. Hypothesis revised: keyword bug.

**Cycle 2 — Syntax variations on read rules to find the working form.**
Tested 3 alternatives. V2 (`function 1, address >2`): rejected — `invalid modbus option`. V3 (`access read coils; modbus: address >2`): rejected — `address` cannot be a standalone keyword. V4 (`access coils, address >2` — no read/write qualifier): rejected. Only the original `access read|write <table>, address <comparator>` form parses. Cycle 1's behavior confirmed: comparator form parses but doesn't filter on reads.

**Cycle 3 — Exact-match (V5) vs range (V6) on read rules.**
V5 (`address 0`, exact): parsed cleanly, fired ZERO alerts on PDUs with `addr=0`. Mystery — possibly `address 0` parsed as sentinel "no constraint" by the keyword's internal logic. Unverified for other exact values; flagged as Keyword Finding §5. V6 (`address 3<>65535`, range): parsed cleanly AND fired correctly — excluded the in-map-only `RdHoldRegs addr=0 qty=3` while including all out-of-map and boundary-crossing reads. Range form selected for 9000014/9000015 (rev bumped to 2).

**Cycle 4 — Write rules: characterize `<3` behavior and choose between P/Q/R.**
Predicted-vs-observed mismatch on scenarios 3, 4, 4b under the V1 `<3` form: scenario-3 expected 60, observed 0; scenario-4 expected 121, observed 61; scenario-4b expected 60, observed 60. Cross-referencing addresses that fired vs didn't: `<3` matched addresses 0 and 1, silently excluded address 2. Off-by-one bug — `<N` behaves as `<(N-1)`.
- Path P (`address -1<>3`): rejected at parse time, negative bounds not allowed.
- Path Q (`address <4`, off-by-one compensation): worked, produced exact predictions. Rejected on rule-honesty grounds — rule text would say `<4` but actually match 0,1,2 only due to bug compensation; future readers would be misled, and the rule would silently start over-matching if Suricata fixed the bug in 8.x.
- Path R (drop address sub-clause entirely): parsed cleanly, fired on all expected PDUs PLUS scenario-2's writes to unmapped addr=5 (which are themselves legitimate detection per `monitoring.md` §5 row 1 — no legitimate writer exists). Selected for 9000012/9000013 (rev bumped to 3).

Final result: 6/6 prediction match on the full rerun. Comparator forms (V1, Q) were both technically capable of producing the same alert counts on scenarios 3/4/4b under the buggy semantics, but R was chosen for rule honesty + robustness against upstream Suricata changes.

---

## Findings

Six empirical findings on Suricata 8.0.5 modbus keyword behavior, plus two harness findings. Each framed as a detection-design lesson, not a vendor complaint — the deeper lesson is **empirical verification before relying on documented behavior**, and **use the robust subset of any keyword** rather than work around bugs.

### Keyword Finding §1 — `function N` matches as documented

`modbus: function 2;` and `modbus: function 4;` fire exactly once per matching PDU. Deterministic, no edge cases observed. This is the keyword's working subset and the most predictable primitive for FC-based baseline-violation detection.

**Lesson:** for simple "does FC X appear" detection, prefer the `function N` form over `access read|write <table>` even when both would work — smaller surface area, smaller bug exposure (chosen for 9000010/9000011). Forensic-level distinction between FCs within a class (e.g. FC 5 vs FC 15) lives in the pcap, not the alert msg.

### Keyword Finding §2 — `access read|write <table>` matches the FC class correctly

`access write coils` fires on FC 5 (Write Single Coil) AND FC 15 (Write Multiple Coils). `access write holding` fires on FC 6 AND FC 16. `access read coils` = FC 1, `access read holding` = FC 3, `access read discretes` = FC 2, `access read input` = FC 4. These map cleanly onto the Modbus spec's FC classes and are usable as the primary write/read filter.

**Lesson:** the `access <op> <table>` form is a useful semantic grouping — alerts can carry the security signal ("a write happened from a non-authorized source") without needing per-FC granularity. Forensic-level FC distinction lives in the pcap, not the alert msg.

### Keyword Finding §3 — `address <comparator>` is silently broken on `access read` rules

Tested forms: `address >N`, `address <N`. Both parse without error. Neither filters at match time on read rules — the clause is silently no-op, and the rule fires as if the clause didn't exist. Smoking gun: V1 rule `address >2` fired on `RdHoldRegs addr=0 qty=3`, which has zero addresses in the `>2` range.

**Lesson:** `>` / `<` comparators on `access read` rules are unsafe — silently match-all-on-the-FC-class regardless of what the rule text says. This is the WORST failure mode for a detection rule: it parses, it fires, but it doesn't filter, and the operator has no warning that the address clause is doing nothing.

### Keyword Finding §4 — `address <N>` on `access write` rules is silently off-by-one

`address <3` interprets as `address <(3-1) = <2`. Matches addresses 0 and 1 only; silently excludes address 2. This silently misses every attack at the highest mapped address — in this lab, coil 2 (the High_Alarm coil, target of scenario 3's operational-deception attack from MASTER.md Finding §6). Same bug class as §3 (comparator silently doesn't do what the text says) but with a different failure mode (off-by-one rather than no-op-match-all).

**Lesson:** comparator forms on the modbus keyword cannot be trusted on either reads or writes in Suricata 8.0.5. The detection rule that ships in 3b therefore drops address filtering on writes entirely (relying on source-IP + write-class as the durable primitive) and uses the range form `X<>Y` on reads (the one comparator-shaped form that does behave correctly).

### Keyword Finding §5 — `address X<>Y` range form works AND has a useful semantic

Tested form: `address 3<>65535` on read rules. Parsed cleanly, fired correctly. Empirically determined semantic: the rule matches if **any address in the read range** falls within `[X, Y]` (exclusive of both bounds, per upstream docs). This is RICHER than start-address-only matching:

- `RdCoils addr=0 qty=6` (reads coils 0..5) — the read crosses the in-map/out-of-map boundary; alert fires. Boundary-crossing reads are themselves suspicious (an attacker enumerating beyond the documented map) so flagging them is correct security behavior.
- `RdCoils addr=100 qty=8` — fully out-of-map; alert fires.
- `RdHoldRegs addr=0 qty=3` (reads HR 0..2) — fully in-map; alert correctly does NOT fire.

**Lesson:** the range form's "any-address-in-range" semantic is **more useful than the start-address-only semantic the original detection design intended**. The keyword's actual behavior is a better detection model than what I'd planned. This is the inverse of the §3 and §4 bugs — sometimes empirical verification reveals the keyword does MORE than documented, in a way that improves detection rather than degrading it.

### Keyword Finding §6 — `address N` exact-match form has anomalous N=0 behavior (unverified for other N)

Tested form: `modbus: access read coils, address 0` on scenario-2. Parsed cleanly. Fired ZERO alerts on `RdCoils addr=0 qty=6` and `RdHoldRegs addr=0 qty=3` — both have `request.read.address == 0` and SHOULD have matched. Hypothesis: `address 0` may be parsed as sentinel "no constraint" by the keyword's internal logic. Not tested for other N values (e.g., `address 100` against an addr=100 PDU) due to time-budget on the investigation.

**Lesson:** exact-match form behavior is unverified beyond N=0. Don't trust it without per-value empirical confirmation. Held as an open question for 3c or a future bug-bisection session.

### Harness Finding §1 — `tcpdump -i any` inside a container yields bad-checksum pcaps; default Suricata pcap-file mode rejects them from app-layer inspection

Symptom: scenario-2 first replay run fired zero modbus alerts despite valid PDUs. Root cause: kernel checksum offload + in-container `tcpdump -i any` capture vantage = outbound packets captured before checksums computed. Suricata's `stream.checksum-validation: yes` (default) blocks bad-checksum packets from app-layer reassembly, even with `-T` config-test passing.

Resolution: per-run `-k none` flag for offline pcap replay. Keeps daemon defaults intact for live capture later.

**Lesson for the lab:** any future pcaps captured via in-container tcpdump need `-k none` for Suricata replay. The cleaner long-term fix is to capture pcaps from the host bridge interface (`tcpdump -i br-<bridge-id>`) where checksums are computed correctly, but that requires running tcpdump on the host (privileged) rather than in the container — different operational model.

**Lesson for ICS IDS replay generally:** checksum validation is the silent killer of offline replay testing. Always check the Suricata startup warning for the `1/Nth of packets have an invalid checksum` line before trusting alert counts.

### Harness Finding §2 — Mid-stream pcap captures block app-layer parser engagement entirely

Symptom: baseline pcap with `-k none` produced zero modbus events. Not "events but no alerts" — zero events. The flow record showed `app_proto: "-"` and `app_layer.flow.modbus: 0`. Drilling in: the baseline pcap starts mid-stream — first packet is PSH+ACK with real sequence numbers, no SYN/SYN-ACK/ACK handshake captured.

Suricata's TCP stream reassembly requires the handshake to track stream state. Without it, `flow:established` doesn't match and the app-layer protocol detector doesn't engage. The TCP layer is decoded fine (decoder counters show 180 / 2502 packets accepted), but the modbus parser sits above stream reassembly and never sees any reassembled bytes.

This is **independent of checksum validation**. Even with `-k none`, mid-stream captures can't be app-layer-validated.

**Lesson:** baseline pcaps for FP validation must include the TCP handshake. Restart the application (in this case FUXA) so its long-lived TCP connection re-establishes, THEN capture, so the SYN-SYN/ACK-ACK is in the pcap. Both existing baseline pcaps in this lab (`phase2-baseline-clean-2026-05-22.pcap` and `modbus-baseline-20260520.pcap`) were captured during steady-state FUXA polling and lack the handshake. Recapture is a held item for after 3b ships.

**Lesson for ICS IDS deployment:** in a live deployment, an IDS started AFTER long-lived connections are established will have degraded app-layer detection on those flows — `flow:established` clauses won't match, and protocol parsers may need handshake state to engage. Re-detection on connection drop/reconnect is a deployment consideration.

---

## Architectural Decisions

Two design choices made during 3b that warrant explicit documentation — they were judgment calls, not auto-derived from the findings.

### Decision §1 — V6 range form (`address 3<>65535`) on read rules instead of `address >2` comparator

Driving consideration: Keyword Finding §3 (comparators silently no-op on read rules) forced the change. Range form was chosen over the exact-match form (§6 unverified) and over byte_test fallback (verbose, mixes with the rest of the rule style).

The byte_test fallback was deliberately rejected — even though it would be bulletproof, mixing byte_test rules with modbus-keyword rules in the same ruleset would be visually inconsistent and harder to audit. The range form keeps the ruleset uniform.

Side benefit: V6's "any-addr-in-read-range" semantic catches boundary-crossing reads (Keyword Finding §5) which the original `>2` start-address-only intent would have missed. Detection coverage improved as a side effect of working around the comparator bug.

### Decision §2 — Path R (drop address sub-clause) on write rules instead of Path Q (off-by-one compensation `<4`)

Three options were on the table after Keyword Finding §4 surfaced the write-rule off-by-one:

- **P** (`address -1<>3`, exclusive range): rejected at parse time, negative bounds not allowed.
- **Q** (`address <4`, off-by-one compensation): tested, worked correctly under the buggy `<(N-1)` semantic — `<4` matches 0,1,2 as desired.
- **R** (no address sub-clause): tested, worked, fires on any write from `!$FUXA_IP`.

Chose R over Q on four axes:

1. **Rule honesty:** Q's text says `<4` but actually matches `<3` due to bug compensation. Future readers would need a paragraph of comments to understand why. R says what it does.
2. **Robustness:** if Suricata fixes the off-by-one in 8.0.6+, Q would suddenly start matching addr=3 (an unintended over-fire). R is independent of the comparator bug.
3. **Coverage:** R catches scenario-2's writes to unmapped addr=5 — those ARE legitimate detection per `monitoring.md` §5 row 1 ("any write FC — no legitimate writer exists"). Q would have silently dropped them.
4. **Simplicity:** R is one fewer sub-option per rule, easier to read.

The cost of R is loss of precision in the alert msg ("write to coil from non-FUXA source" rather than "write to MAPPED coil from non-FUXA source"). That cost is acceptable given the lab's threat model — no legitimate writer exists, so address granularity isn't security-relevant for triage; the pcap distinguishes mapped vs unmapped writes for forensic-level detail.

---

## Live-daemon section (separate stream — minimal output expected, same as 3a)

The Suricata daemon continues running in live-capture mode (af-packet on eth0 + eth1, see compose `command:`). Its eve.json lands in `suricata/logs/eve.json` (separate from the offline replay outputs in `suricata/logs/replay-3b-*/eve.json`).

The Docker bridge MAC-learning constraint identified in 3a still applies: the live daemon sees broadcasts + its own traffic, not unicast between other containers. The modbus parser being enabled doesn't change this — it changes WHAT gets parsed once a packet reaches Suricata, not WHETHER the packet reaches Suricata in the first place.

**Live-daemon eve.json remains near-empty for 3b**, same as 3a. The 251 attack alerts above came from offline replay; live-capture validation is queued for 3c (likely via `--network host` mode for Suricata, or via iptables NFLOG bridge mirroring).

Do not conflate the live daemon's near-empty eve.json with "no alerts fired." The 3b evidence stream is the six `replay-3b-*` directories.

---

## Cross-references

### Resolved (exist on disk)

- `docs/phase2/scenarios/scenario-2-modbus-fc-scan.md` — FC scan + out-of-map reads attack.
- `docs/phase2/scenarios/scenario-3-coil-writes.md` — FC 5 to alarm coil (operational deception).
- `docs/phase2/scenarios/scenario-4-hr-writes.md` — FC 6 + FC 16 to mapped HRs.
- `docs/phase2/scenarios/scenario-4b-fc15-coils.md` — FC 15 to mapped coils.
- `docs/monitoring.md` §5 (suspicious-indicator table) — rows 1, 3, 6 directly covered by 3b's ruleset.
- `docs/MASTER.md` Phase 2 Finding §4 (silent zeros vs exception 02 on out-of-map reads) — justifies why 9000014/9000015 use address inspection instead of exception watching.
- `docs/MASTER.md` Phase 2 Finding §6 (operational deception via alarm-coil write) — the security story 9000012 detects.
- `docs/MASTER.md` Phase 2 Finding §8 (rate-threshold non-determinism) — justifies why all 3b rules are protocol-aware with no rate thresholds.
- `docs/phase2/detection/3a-recon-detection.md` — predecessor sub-session; structure mirrored here.
- `suricata/suricata.yaml` — modbus app-layer parser block (added in 3b).
- `suricata/rules/local.rules` — 6 new rules (SIDs 9000010–9000015) appended; 3a's 5 rules unchanged.
- `suricata/logs/replay-3b-{scenario-2,scenario-3,scenario-4,scenario-4b,baseline-phase1,baseline-phase2}/{eve.json,fast.log,stats.log,suricata.log}` — raw evidence (gitignored).
- `captures/phase2-scenario-{2,3,4,4b}-2026-05-22.pcap` — attack pcaps (gitignored).
- `captures/phase2-baseline-clean-2026-05-22.pcap` + `captures/modbus-baseline-20260520.pcap` — baseline pcaps (gitignored).
- `plc/tank_fill.st` — PLC source, map cutoffs verified against lines 21–27 and 42–47.

### Forward references — MANUAL until sub-session exists

- **Sub-session 3c — replay attack detection + live-capture revisit.** Will address scenario 5's replay attack (different signal class — captured-PDU replay rather than fresh PDUs from attacker's stack), plus the live-capture work deferred from 3a/3b. Doc will land at `docs/phase2/detection/3c-replay-attack.md` — **does not exist yet (MANUAL: to be authored as Phase 2 sub-session 3c ships).**

### Held items (logged for after 3b commits)

- **Recapture baseline pcaps with TCP handshake included.** Restart FUXA (or kill its Modbus connection) so the next baseline tcpdump captures from the handshake start. Enables real false-positive validation that Harness Finding §2 currently blocks.
- **Test exact-match form for N≠0** to characterize Keyword Finding §6 fully. ~5 min of additional replay testing.
- **FUXA Modbus client silent-reconnect investigation.** Mid-3b session, FUXA's Modbus client silently dropped (HMI tank stopped rendering). Wire-level grep showed zero ESTABLISHED connections; recreate fixed it. Configure an explicit reconnect interval in FUXA's device config (`./fuxa/appdata`) so retry is automatic on drop. Becomes a Known Risks entry in MASTER.md.
- **Pin Suricata's IPs** (currently next-free-slot at `172.18.0.4 / 172.19.0.4`) — small operational follow-up from 3a still queued.

---

## Authoring discipline self-check

- All cited paths verified to exist on disk OR explicitly flagged MANUAL (3c).
- Date stamp (2026-05-24) matches `date -Iseconds` at session start.
- Cross-references to MASTER.md findings (§4, §6, §8) verified against MASTER.md content during pre-write.
- Cross-references to monitoring.md §5 rows verified against monitoring.md content.
- Cross-references to plc/tank_fill.st line ranges verified against file content.
- Cross-references to scenario .md files use the actual filenames as listed by `ls`, not the handoff-narrative-version names.
- All command examples (suricata invocations) shown with the exact flags used in the recorded runs, not paraphrased.
