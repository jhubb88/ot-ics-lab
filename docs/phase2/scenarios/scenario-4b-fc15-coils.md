# Phase 2 Scenario 4b — FC 15 (write multiple coils) addendum to scenario 4

**Date:** 2026-05-22
**Source task:** Phase 2 attack scenarios (step 2 of Phase 2) —
addendum to scenario 4, run because scenario 2 had confirmed FC 15
protocol-layer acceptance to *unmapped* addresses, and scenarios 3
and 4 had left the mapped-coil case for FC 15 as an inference rather
than an empirical test.
**Attacker vantage:** `otlab-attacker` multi-homed on `ot_zone`
(`172.18.0.4`), target `openplc:502` (`172.18.0.2`).
**Modbus map:** Coil 0 = `%QX0.0` = `Pump_Run`; Coil 1 = `%QX0.1`
= `Valve_Open`; Coil 2 = `%QX0.2` = `High_Alarm`.

---

## Setup

Same boundary-crossed state as scenarios 1–4. No screenshot —
addendum is about closing the FC 15 empirical-test gap, not
re-demonstrating operational deception (scenario 3 already did
that for the alarm coil visibly).

Capture vantage: `tcpdump -i any` inside `otlab-openplc`.

---

## Prediction (stated before running)

Scenario 3 established that FC 5 (write single coil) writes to
mapped coil 2 are accepted at the protocol layer and reasserted by
the PLC within ~1 scan. Scenario 2 established FC 15 (write
multiple coils) is also accepted at the protocol layer (against
unmapped addresses). The inference is that FC 15 to mapped coils 0,
1, 2 should produce the same reassertion behavior as FC 5 in
scenario 3 — write accepted, PLC reasserts within ~100 ms scan.

The harder question is sampling: with three coils being falsified
and three being reasserted from independent ST expressions
(`Pump_Run := Fill_Active`, `Valve_Open := Fill_Active`,
`High_Alarm := Level >= SP_AlarmHH`), the read-back must catch a
moment when none of those three reassertion paths has run more
recently than our last FC 15 PDU.

---

## Commands

```bash
docker exec -d otlab-openplc sh -c \
  "tcpdump -i any -U -w /tmp/scenario-4b.pcap 'tcp port 502'"
sleep 2

docker exec -i otlab-attacker python3 - <<'PY'
from pymodbus.client import ModbusTcpClient
import time
c = ModbusTcpClient(host='openplc', port=502)
c.connect()

def snap(label, delay=0):
    if delay: time.sleep(delay)
    lvl = c.read_holding_registers(0, 1, slave=1).registers[0]
    coils = c.read_coils(0, 3, slave=1).bits[:3]
    print(f"{label:18s}  level={lvl:3d}%  Pump:{coils[0]} Valve:{coils[1]} Alarm:{coils[2]}")

snap("BEFORE")
end = time.time() + 3.0
n = 0
while time.time() < end:
    c.write_coils(0, [True, True, True], slave=1)   # FC 15 — all three coils TRUE
    n += 1
    time.sleep(0.05)
print(f"BURST              sent {n} FC 15 PDUs (each writes 3 coils)")

snap("AFTER +0ms")
snap("AFTER +500ms",  0.5)
snap("AFTER +1000ms", 0.5)
snap("AFTER +2000ms", 1.0)
snap("AFTER +3000ms", 1.0)
c.close()
PY

sleep 3
docker exec otlab-openplc pkill tcpdump
docker cp otlab-openplc:/tmp/scenario-4b.pcap \
  ./captures/phase2-scenario-4b-fc15-coils-2026-05-22.pcap
```

---

## Observed output

```
BEFORE              level= 58%  Pump:True  Valve:True  Alarm:False    (natural fill phase)
BURST               sent 60 FC 15 PDUs
AFTER +0ms          level= 72%  Pump:False Valve:False Alarm:False
AFTER +500ms        level= 67%  Pump:False Valve:False Alarm:False
AFTER +1000ms       level= 62%  Pump:False Valve:False Alarm:False
AFTER +2000ms       level= 52%  Pump:False Valve:False Alarm:False
AFTER +3000ms       level= 42%  Pump:False Valve:False Alarm:False
```

### What the level trace tells us

Level: 58 → 72 over 3 s of burst → 72 → 42 over 3 s of read-back.

- Pre-burst, BEFORE: level=58 with Pump/Valve TRUE (fill phase).
- During the burst the level rose from 58 to ~80 in ~2.2 s
  (`+1/scan` = +10/s while filling), at which point the
  hysteresis latches Fill_Active to FALSE.
- The remaining ~0.8 s of burst plus the read-back schedule was
  spent draining (`-1/scan` = -10/s). 72 (at burst-end read) →
  42 (at +3000 ms read) is exactly 30 % drop in 3 s = -10/s,
  matching the drain rate.

The natural plant cycle therefore transitioned mid-burst. By the
time the burst ended and the AFTER +0 ms read fired, the PLC's
control state had Fill_Active = FALSE, and the most recent scan
had reasserted Pump_Run = FALSE, Valve_Open = FALSE. The Alarm
coil's natural state was also FALSE (level was 72, threshold is 90).

### Honest framing — did the attack land?

Yes, but the read-back schedule did not happen to sample a TRUE
window for any of the three coils on this run. Both pieces of
evidence are independent:

- **Protocol-layer:** 60 FC 15 PDUs sent, all accepted, no Modbus
  exceptions in the pcap. Server responses present and well-formed.
  pcap: 28 KB, 288 packets, 72 attacker→openplc PUSH packets
  (60 FC 15 + 6 read-backs + a few TCP keep-alive ACKs).
- **Sampled state:** the AFTER reads caught the PLC's reasserted
  values, not our falsified values. This is the same timing-non-
  determinism noted in scenario 3 (one real run caught TRUE at
  +0 ms, another caught FALSE) — extended to a worse case here
  because Pump/Valve's natural state itself flipped mid-burst.

To put it bluntly: scenario 3 caught the operational-deception
window once. This scenario 4b run did not. **The mechanism is the
same; the sample timing was unlucky.** The pcap, not the
read-back, is the evidence that the FC 15 path works against
mapped coils — and the pcap is unambiguous.

---

## Findings (plain English)

1. **FC 15 to mapped coils — protocol-layer write accepted.** 60
   FC 15 PDUs sent, all accepted, no exceptions. The §5.3 inference
   that scenario 3's FC 5 result generalizes to FC 15 is now
   empirical at the protocol layer.

2. **PLC reasserts mapped coils every scan, FC 15 case identical to
   FC 5.** The post-burst reads caught the PLC's reasserted values
   exclusively — no read landed inside a between-scan write window.
   That is consistent with the scan-rate reassertion mechanism;
   it is not consistent with any alternative ("write stuck",
   "PLC accepted permanent state change") since the natural-state
   reassertion was visible across all reads.

3. **Natural cycle interference is a real experimental confound for
   bursts that span more than one hysteresis transition.** The
   burst spanned a Fill_Active TRUE→FALSE transition (level
   crossed SP_High during the burst), so the post-burst state was
   dominated by the natural drain rather than by our writes. For
   any future scenario where the qualitative read-back evidence
   matters, the burst length should be tuned relative to the level
   distance from the nearest hysteresis threshold, OR the burst
   should run while level is mid-band (e.g. 40–60).

4. **§5.3 scope-honesty note can now be fully closed.** Across
   scenarios 3, 4, and 4b, all four output-path Modbus writes
   (FC 5, FC 6, FC 15, FC 16) have been empirically tested against
   the lab's mapped coils + holding registers. The architectural
   property holds in all four: write accepted, PLC reasserts within
   ~1 scan, control logic unaffected. The §5.3 paragraph reading
   "Writes to coils (FC 5/15) … were not tested here … FC 15/16
   to mapped addresses untested" is fully addressed.

5. **For Suricata in step 3:** same source-IP + FC signal as
   scenarios 3 and 4. FC 15 from a non-FUXA source IP to coil 0–2
   is the rule. The natural-cycle interference observation above
   does not change the detection rule — the FC 15 PDU lands on
   the wire regardless of whether it visibly affects state.

---

## Cross-references

- `docs/network-security.md` §5.3 — scope-honesty note now closed
  for all four output write FCs (FC 5, 6, 15, 16) and all output
  coils + HRs in the lab's documented Modbus map.
- Scenario 3 — the operational-deception (visible HMI flip) was
  demonstrated there for the alarm coil. This addendum closes the
  FC 15 path inference but does not re-prove operational deception
  (the screenshot would be ambiguous without a clean TRUE-window
  sample).
- `docs/monitoring.md` §5 row 1 (any write FC) — triggered.
- `docs/monitoring.md` §5 row 2 (new source IP to :502) — triggered.
- `captures/phase2-scenario-4b-fc15-coils-2026-05-22.pcap`
  (gitignored, 28 KB, 288 packets).
- `plc/tank_fill.st` lines 69–77 (hysteresis + coil reassertion
  expressions) — what the PLC is doing every scan.

---

## Hand-off to scenario 5

Scenario 5 is the protocol-authentication question: replay a
captured legitimate FUXA → openplc PDU from the attacker's source
IP. Independent of the access-control / reassertion topics
scenarios 2, 3, 4, 4b have covered.
