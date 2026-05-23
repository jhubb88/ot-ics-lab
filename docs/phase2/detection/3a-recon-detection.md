# Phase 2 Step 3a — Recon Detection (Suricata Sub-session 1 of 3)

**Date:** 2026-05-23
**Source task:** Phase 2 step 3 (Suricata passive monitoring), sub-session 3a — recon-detection ruleset.
**Subject pcap:** `captures/phase2-scenario-1-recon-2026-05-22.pcap` (scenario 1's nmap recon).
**Result:** 3 of 5 SIDs fired (75 alerts total). 2 SIDs did not fire — diagnostic captured below; both are valuable findings, not failures.

---

## Setup

### Suricata deployment

New `suricata` service in `docker-compose.yml`, multi-homed on `ot_zone` + `mgmt_zone`:

- **Image:** `jasonish/suricata:8.0.5` (pinned semver — same supply-chain stance as `frangoteam/fuxa:1.3.1`)
- **Mode:** IDS (alert only, no drops, no flow modification)
- **Live capture:** af-packet on `eth0` (ot_zone) + `eth1` (mgmt_zone), `tpacket-v3`
- **Memory ceiling:** `mem_limit: 512m` (resident ~67 MB observed at idle, 13% utilization)
- **Capabilities:** `cap_add: NET_ADMIN + NET_RAW` (no privileged mode — Phase 1 least-privilege stance)
- **Bind mounts:**
  - `./suricata/suricata.yaml → /etc/suricata/suricata.yaml` (read-only)
  - `./suricata/rules → /etc/suricata/rules` (read-only)
  - `./suricata/logs → /var/log/suricata` (writable)
  - `./captures → /captures` (read-only — for offline pcap analysis)

### Sensor placement — both networks

Both `ot_zone` AND `mgmt_zone`. The decision derives from Phase 2 Finding §2: the legitimate FUXA↔OpenPLC Modbus poll rides `mgmt_zone` (172.19.0.x); attacker traffic from a boundary-crossed attacker rides `ot_zone` (172.18.0.x). A sensor on only one network misses half the story.

### IP-slot continuity note

Pinned IPs were added in this sub-session for `openplc` + `fuxa` via docker-compose `ipv4_address`:

- openplc: `172.18.0.2` (ot_zone) / `172.19.0.2` (mgmt_zone)
- fuxa:    `172.18.0.3` (ot_zone) / `172.19.0.3` (mgmt_zone)

Suricata is currently **not** pinned — Docker assigned it the next-free slot on each network, `172.18.0.4 / 172.19.0.4`. This creates a continuity issue worth knowing:

- During Phase 2 step 2's attack scenarios (2026-05-22), the attacker container was boundary-crossed into ot_zone and got `172.18.0.4` (Docker assigned the next-free slot after openplc=.2, fuxa=.3). **Step 2's pcaps show 172.18.0.4 as the attacker's source IP.**
- Going forward (post-3a bring-up), Suricata holds the .4 slot. If the attacker is boundary-crossed again with Suricata running, Docker will assign the attacker `172.18.0.5` (or the next free slot).

So `172.18.0.4` appearing in any LIVE eve.json (sub-sessions 3b/3c) is Suricata, not the attacker. The pcap evidence from step 2 keeps showing .4 as attacker because the network state at capture time had .4 free.

Pinning Suricata to .4 explicitly (so the IP semantics are deterministic) is queued as a small follow-up commit after this evidence doc is shipped.

### Capture method — offline pcap replay

The verification method for 3a is **offline pcap replay** via `suricata -r`, not live capture. Reasons:

1. **Docker bridge MAC learning limits live-capture visibility.** A passive Suricata container on a Docker bridge sees broadcasts + its own traffic, but does NOT see unicast traffic between other containers (the bridge's MAC table forwards unicast only to the destination port). Known Docker-IDS limitation; flagged in Step 1.
2. **The 3a goal is rule-validation against a known attack.** Scenario 1's pcap was captured during a known recon attack; replaying it answers "would these rules have caught it?" — exactly the question 3a is designed to answer.
3. **3b and 3c will revisit live-capture.** The live-daemon limitation isn't a blocker for 3a — it's an explicit hand-off to later sub-sessions.

Replay command:

    docker exec otlab-suricata suricata \
      -r /captures/phase2-scenario-1-recon-2026-05-22.pcap \
      -c /etc/suricata/suricata.yaml \
      -l /var/log/suricata/replay-3a -v

Output isolated under `suricata/logs/replay-3a/` so live-daemon output (effectively empty due to bridge MAC learning) doesn't mix with offline analysis evidence.

---

## Ruleset

Five rules in `suricata/rules/local.rules`. SID range `9000001–9000005` reserved for this lab.

Each rule was designed to detect a specific recon indicator from `docs/monitoring.md` §5:

| SID | Detection | monitoring.md §5 row |
|---|---|---|
| 9000001 | ICMP echo-request burst (≥5 ICMPs from one src in 10s) | row 5 (connection churn — extended to ICMP) |
| 9000002 | TCP SYN burst (≥10 SYNs from one src in 10s) | rows 2 + 3 (new source + FC scanning, generalized) |
| 9000003 | TCP SYN to openplc:502 from any source NOT FUXA | row 2 (new source IP to :502) |
| 9000004 | TCP SYN to openplc:[8080,8443] from any non-operator source | extends row 2 to the management surface — ties Finding §3 |
| 9000005 | TCP RST burst (≥15 RSTs from one src in 10s) | row 5 (connection churn) |

The 9000003 / 9000004 pair uses pinned IP-set variables (`$FUXA_IP`, `$OPENPLC_IP`, `$MGMT_OPERATOR`) defined in `suricata.yaml`. The pinning of openplc + fuxa to known IPs (via docker-compose `ipv4_address`) is what makes these source-IP-aware rules reliable across restarts.

### Engine warnings — non-blocking

Suricata logged two warnings at rule-load time:

    Warning: detect: rule 9000004: SYN-only to port(s) 8080:8080 w/o direction specified, disabling for toclient direction
    Warning: detect: rule 9000003: SYN-only to port(s) 502:502 w/o direction specified, disabling for toclient direction

Suricata auto-disables these rules for the toclient direction because `flags:S` (SYN-only) inherently means server-bound. Rules still fire for toserver traffic, which is exactly what we want. Adding `flow:not_established,to_server;` to the rules would silence the warning and make intent explicit — queued as a small refinement.

---

## Offline replay output

### Summary

    exit code:            0
    pcap processed:       1171 packets, 109589 bytes (full scenario-1 attack)
    elapsed:              0.103 seconds
    rules loaded:         5 of 5 (0 failures)
    alerts written:       75
    alerts suppressed:    94 (threshold rules deduping repeats from same source — expected)
    output:               suricata/logs/replay-3a/{eve.json, fast.log, stats.log, suricata.log}

### Alerts per SID — three fired, two did not

      40   sid 9000004   OpenPLC web UI from non-operator source
      32   sid 9000003   Modbus :502 from non-FUXA source
       3   sid 9000002   TCP SYN scan (rate threshold)
       0   sid 9000001   ICMP echo-request sweep
       0   sid 9000005   TCP RST connection-churn

All 75 alerts share `src=172.18.0.4` (attacker on ot_zone) → `dst=172.18.0.2` (openplc on ot_zone). Timestamps span `18:04:54.522565 → 18:06:29.244405` — matching scenario 1's ~95-second nmap session end-to-end.

### Per-SID firing detail

#### SID 9000004 — OpenPLC web UI from non-operator source (40 alerts)

Fired on every nmap probe of openplc's `:8080` OR `:8443`. Both ports are present (recall Finding §3: openplc serves HTTPS on `:8443` too, undocumented in Phase 1).

First 3 alerts (chronological):

    18:04:54.522756   172.18.0.4:53788 -> 172.18.0.2:8080
    18:04:54.523133   172.18.0.4:51720 -> 172.18.0.2:8443    <-- the undocumented port from Finding §3
    18:04:54.872708   172.18.0.4:35452 -> 172.18.0.2:8080

The single `:8443` alert is independently confirmed by scenario 1's recon finding — Phase 1 port docs missed 8443; Phase 2 found it; Suricata now alerts on it. End-to-end coverage.

#### SID 9000003 — TCP SYN to Modbus :502 from non-FUXA source (32 alerts)

Fired on every nmap probe of openplc's `:502` (the entire point of an ICS attacker: get to Modbus). `monitoring.md` §5 row 2 ("Only FUXA should talk to the PLC") translated directly into rule, and the rule does exactly what §5 promised.

First 3 alerts (chronological):

    18:04:54.523033   172.18.0.4:43958 -> 172.18.0.2:502
    18:04:54.872754   172.18.0.4:35452 -> 172.18.0.2:502
    18:04:54.946848   172.18.0.4:43964 -> 172.18.0.2:502

Tight latency from start of recon — first alert ~0.5s after scan began. Suricata catches the attacker contacting Modbus on the first SYN.

#### SID 9000002 — TCP SYN scan rate threshold (3 alerts)

Fires when one source emits ≥10 SYNs in any 10-second window. Three alerts means three separate 10s windows where the threshold tripped. The threshold mode `type both, track by_src` makes Suricata alert at the trigger point then suppress repeats for the window. The 94 `alerts_suppressed` counter in `stats.log` captures the repeats.

Three alerts at:

    18:04:54.946848   (window 1 — initial scan burst)
    18:05:22.045085   (window 2 — service version probes)
    18:05:33.102740   (window 3 — service version probes)

This is correct behavior. Without the suppression, every SYN past the threshold would re-alert and flood eve.json.

**Limitation worth flagging — rate-threshold evasion via slow scanning.** The 10 SYNs / 10s threshold catches nmap's default timing (`-T3`) and faster (`-T4`, `-T5`) but would miss slower scans: `-T2` "polite" (≥0.4s between probes) or `-T1` "sneaky" (≥15s between probes). Low-and-slow recon evades rate-threshold rules by design — a real defender pairs rate rules with cumulative flow tracking (track unique destinations per source over a long window, regardless of rate) to cover both. Tracked for 3b/3c.

### SIDs that did NOT fire — diagnostic

These are not failures. They are findings.

#### SID 9000001 — ICMP echo-request sweep (0 alerts)

Pcap content count:

    ICMP echo-request packets:    0
    ICMP packets of any type:     0
    ARP packets:                  0   (capture filter excluded ARP)

**Why it didn't fire:** the scenario-1 pcap contains zero ICMP packets. `nmap -sn 172.18.0.0/24` from inside a Docker bridge did not send ICMP echo-requests. Cause is a well-known nmap behavior: when nmap detects that targets share its broadcast domain (same Layer-2 segment), it uses ARP for host discovery instead of ICMP. ARP is more reliable than ICMP for local subnets and skips the kernel's ICMP path entirely.

The scenario-1 pcap capture filter was `'tcp or icmp'` (per `docs/phase2/scenarios/scenario-1-recon-nmap.md` setup), which excluded ARP at capture time. So even if we wanted to write an ARP-based detection rule, the existing pcap couldn't be used to test it.

**The lesson — signature-based recon detection has to match the actual reconnaissance method, not the textbook one.** On a Docker bridge (and on a real OT subnet where targets share a broadcast domain), ARP is the host-discovery primitive. A defender writing detection rules from a textbook would miss this. **The gap is more instructive than a fix** — keeping 9000001 in the ruleset as-is documents the assumption that broke down.

**Follow-up consideration (deferred):** Add a future SID (9000006-class) ARP-flood detection rule, with a fresh pcap captured *without* the `'tcp or icmp'` filter (so ARP is captured). Tracked as MANUAL future work — Phase 2 sub-session 3b or later.

#### SID 9000005 — TCP RST connection-churn (0 alerts)

Pcap content count:

    Total RST packets in pcap:                    42 (22 inbound, 20 outbound from openplc)
    Max RST burst from one direction in 10s win:   6
    Rule threshold:                               15

**Why it didn't fire:** the max RST burst from any single source in any 10-second window was 6 — well below the rule's 15/10s threshold. nmap -sT against this lab generates only ~12 server-side RSTs total (one per closed port × 2 hosts × ~6 closed ports), spread over the ~95-second scan.

**Deeper semantic problem for this scan type (the more interesting finding):** scenario 1 used `nmap -sT` (full connect scan). In -sT, RSTs come from the *server* closing connections to closed ports — not from the *scanner*. So even if the rule's 15/10s threshold had been met against this pcap, the source-IP tracking would have flagged **openplc as the RST source**, not the attacker. Lowering the threshold would generate false confidence: alerts on the wrong source IP, with the operator wrongly suspecting openplc of malicious behavior.

**For nmap -sS (SYN scan, half-open), the dynamic flips:** the scanner sends RSTs to tear down half-open connections, and source-IP tracking would correctly attribute to the attacker. The rule isn't universally broken — it's inverted for the specific scan type scenario 1 used.

**The lesson — RST-based detection has to account for which scan type it's countering.** A robust cross-scan-type rule would track unique destinations per source per time window (flow-based anomaly detection), not raw RST counts. Marked TBD for the redesigned ruleset in sub-sessions 3b/3c.

---

## Findings (technical)

1. **Recon detection works for the rules that match the actual attack traffic, even before tuning.** 3 of 5 rules detected the recon end-to-end: every Modbus :502 probe (9000003), every web-UI probe including the undocumented :8443 (9000004), and the SYN-rate threshold caught the scan as a bulk pattern (9000002). 75 alerts generated, 94 suppressed by intentional dedup, 0 false positives in the offline replay.

2. **Signature-based recon detection has to match the actual reconnaissance method, not the textbook.** nmap on Docker bridges (and on flat OT subnets generally) uses ARP for host discovery, not ICMP. The 9000001 rule is built for the textbook attack and doesn't see the real one. Keeping the rule as-is documents the assumption that broke down — better learning than a quiet rewrite.

3. **RST-based scan-churn detection is semantically inverted for nmap -sT (full connect scans), which is what scenario 1 used.** For -sT, RSTs come from the *server* closing connections to closed ports, so a rule that counts RSTs per source flags the server, not the scanner. For nmap -sS (SYN scans), RSTs come from the *scanner* tearing down half-open connections, and the same rule would correctly attribute to the attacker. Detection design has to account for which scan type is being countered. Real port-scan detection that's robust across scan types needs flow-based anomaly tracking (unique destinations per source per time window), not raw RST counting. The 3a rule isn't universally broken — it's inverted for the specific attack pattern in scenario 1. Redesign for cross-scan-type coverage is a 3b/3c concern.

4. **The cross-reference to Finding §3 (documentation-drift hardening trap) is empirically confirmed.** SID 9000004 fired on the attacker's :8443 probe. Phase 1 docs listed only :8080. If Phase 3 hardening firewalls only :8080, this rule is the safety net that catches the leftover :8443 attack surface. The two findings reinforce each other: Finding §3 says "the docs are incomplete"; SID 9000004 says "even with incomplete docs, we have detection on both ports."

5. **Pinning IPs for legitimate services (FUXA, openplc) via docker-compose `ipv4_address` is a prerequisite for source-IP-aware detection, not an afterthought.** SIDs 9000003 and 9000004 reference `$FUXA_IP`, `$OPENPLC_IP`, and `$MGMT_OPERATOR` — variables that resolve to specific IPs in `suricata.yaml`. Without docker-compose's `ipv4_address` pinning (added in this sub-session), Docker would auto-assign IPs based on container startup order. Every restart would risk false positives on legitimate traffic (if FUXA happened to land on a different .3) AND silent rule misses (if the attacker happened to land on FUXA's expected IP). The IP-pinning decision is architectural for any source-IP-aware ICS detection — not a Docker quirk to work around, but a layer of the detection design.

---

## Live-daemon section (separate stream — minimal output expected)

The Suricata daemon is also running in live-capture mode (af-packet on eth0 + eth1, see compose `command:`). Its eve.json lands in `suricata/logs/eve.json` (separate from the offline replay output in `suricata/logs/replay-3a/eve.json`).

Per the Docker bridge MAC-learning constraint flagged in Step 1, **the live daemon's eve.json is expected to be near-empty for 3a.** Suricata sees:

- Its own traffic (negligible — passive sensor)
- Broadcast/multicast traffic on each bridge (mostly Docker housekeeping)
- NOT the unicast traffic between fuxa↔openplc (that traffic bypasses Suricata's NIC because Linux bridges forward unicast only to the destination port)

This is not a bug. It is a known Docker-bridge IDS deployment limitation, which sub-sessions 3b/3c will need to work around (likely via either `--network host` mode for Suricata, or via iptables/tc mirroring of bridge traffic). **3a's job is to validate the ruleset against a known attack pcap, not to solve live-capture.**

**Do not conflate the live daemon's near-empty eve.json with "no alerts fired."** The 75 alerts above came from the offline replay, which IS the 3a evidence stream.

---

## Cross-references

### Resolved (exist on disk)

- `docs/phase2/scenarios/scenario-1-recon-nmap.md` — the recon attack this ruleset was designed to detect.
- `docs/monitoring.md` §5 — suspicious-indicator table. Rows 2 (new source IP) and 5 (connection churn) are directly covered; row 3 (FC scanning) is generalized into 9000002.
- `docs/MASTER.md` Phase 2 Finding §3 (documentation-drift hardening trap) — empirically confirmed by SID 9000004's alert on :8443.
- `docs/MASTER.md` Phase 2 Finding §2 (mgmt_zone vs ot_zone) — sensor placement decision (both networks) derives from this finding.
- `suricata/suricata.yaml` — engine config.
- `suricata/rules/local.rules` — the 5 rules with detailed per-rule comments.
- `suricata/logs/replay-3a/{eve.json, fast.log, stats.log, suricata.log}` — raw evidence (gitignored).
- `captures/phase2-scenario-1-recon-2026-05-22.pcap` — scenario 1 attack pcap (gitignored).

### Forward references — MANUAL until sub-sessions exist

- **Sub-session 3b — Modbus protocol parsing.** Will enable Suricata's modbus app-layer parser and add rules for write FCs, function-code scanning, out-of-map reads (Finding §4 says detection here must parse PDUs, not rely on Modbus exceptions). Doc will land at `docs/phase2/detection/3b-modbus-protocol.md` — **does not exist yet (MANUAL: to be authored as Phase 2 sub-session 3b ships).**
- **Sub-session 3c — Replay attack detection.** Will revisit scenario 5's replay attack and the RST-rule-redesign question (anomaly-based flow tracking). Doc will land at `docs/phase2/detection/3c-replay-attack.md` — **does not exist yet (MANUAL: to be authored as Phase 2 sub-session 3c ships).**
- **Suricata IP pinning + SYS_NICE cap + rule flow clauses follow-up commit** — small operational polish identified during 3a bring-up; tracked in the post-3a follow-up queue. Not blocking 3a's evidence; not yet committed.
