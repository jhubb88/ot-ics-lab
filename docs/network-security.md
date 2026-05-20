# Network Security — OT/ICS Security Lab (Phase 1)

The security argument behind the build. `README.md` says *how to run it*;
`docs/architecture.md` says *how it fits*; this document says *why it is
built the way it is, what it does and does not protect, and what an attacker
would see*. Honesty about scope is deliberate — overstating a lab's security
is itself an anti-pattern.

---

## 1. Threat model (Phase 1)

**Assets**
- Process integrity — the tank-fill control loop behaving correctly.
- The PLC program and runtime (`plc/tank_fill.st`, OpenPLC).
- The HMI view an operator trusts (FUXA).

**Adversaries considered**

| Adversary | Position | Phase 1 treatment |
|---|---|---|
| Supply-chain attacker | Upstream image / dependency | **Mitigated** — pinned source build |
| On-path attacker in `ot_zone` | Already on the process network | **Demonstrated, not prevented** — Modbus has no auth (see §5) |
| Attacker in `attacker_zone` | Adjacent, untrusted segment | **Contained** — no route to `ot_zone` (see §4) |
| Host / Docker escape | Container breakout | **Out of scope** Phase 1 (noted in §6) |

**Out of scope (stated honestly):** authentication on Modbus, TLS, host
hardening, Docker daemon hardening, OpenPLC web-UI credential hardening.
Phase 1's job is to *build the realistic system and show the exposure*, not
to harden every layer. Phase 2 backlog (in `docs/MASTER.md`) extends this.

---

## 2. Supply-chain control (the first decision)

There is **no official OpenPLC image on Docker Hub**. Every prebuilt OpenPLC
image is community-maintained with unverified provenance. Pulling one into a
*security* lab would mean the very first action of the project is an
unvetted-code-execution risk.

Mitigation, enforced in `plc/Dockerfile`:

| Control | Implementation |
|---|---|
| No anonymous publisher trust | Built from official upstream repo, not Docker Hub |
| Reproducible build | Pinned to one immutable commit `b5d4135…`, never a branch tip |
| Inspectable before run | Source is cloned + checked out from a known SHA you can review |
| Fail loud, never fall back | Build aborts on a bad commit checkout; no silent branch-tip fallback |
| Pinned base + HMI | `debian:trixie-<date>` and `frangoteam/fuxa:1.3.1` — never `:latest` |

This is the strongest, fully-enforced control in Phase 1 and the headline
talking point: *the lab's threat model starts at where the code comes from.*

---

## 3. Least privilege

Upstream OpenPLC's sample run command uses `--privileged` for GPIO/hardware
I/O. This lab has **no hardware**, so:

- `--privileged` is **deliberately not set** in `docker-compose.yml`.
- The PLC program **simulates its own process** instead of touching I/O.
- Result: a PLC container break-in does not yield host device access; the
  blast radius is the container, not the kernel.

This is a real, demonstrable least-privilege decision, not a default left
unexamined — that distinction is the point in an interview.

---

## 4. Segmentation rationale

Three Docker bridge networks model plant zones:

| Zone | Intent | Phase 1 reality |
|---|---|---|
| `ot_zone` | Process / Modbus PLC↔HMI | Both legit services here |
| `mgmt_zone` | Human web access to UIs | Both legit services here |
| `attacker_zone` | Untrusted adjacent segment | **Empty, no members** |

```
   mgmt_zone ───┐                 ┌─── ot_zone
                │  openplc, fuxa  │   (Modbus :502)
                └────multi-homed──┘
                                          ╳  no route
   attacker_zone  ── (empty) ──────────────╳──────────  ot_zone
                     isolated bridge, default-deny
```

**Honest scope note (important — do not oversell this).**
In Phase 1 both legitimate services are multi-homed on `ot_zone` +
`mgmt_zone` for usability. So `mgmt_zone`↔`ot_zone` is **not** a hard
boundary here — a compromise of either service sits on both networks. That
is a known, accepted Phase 1 simplification, documented rather than hidden.

The **genuinely enforced** boundary is `attacker_zone`. Docker bridge
networks are isolated from one another by default (no inter-bridge route
without explicit attachment or routing). A container placed *only* in
`attacker_zone` therefore has **no path to `ot_zone`** — it cannot even
reach the Modbus port. That is the one boundary Phase 1 can actually
demonstrate, and the one Phase 2's attacker container will probe to prove
(or break) the assumption.

---

## 5. Exposure analysis

### 5.1 Host-published ports

`docker-compose.yml` publishes three ports to the Windows host:

| Port | Service | Why published | Risk |
|---|---|---|---|
| 8080 | OpenPLC web editor | Human management from Windows browser | Default creds `openplc/openplc` — **not hardened in Phase 1** |
| 1881 | FUXA HMI | Operator screen from Windows browser | First-run admin setup; lab-local only |
| 502 | Modbus/TCP | Wireshark / host Modbus tooling reach the PLC | Unauthenticated by protocol design |

These are bound on the host — treat this as a **local lab only**, never
exposed to an untrusted network. That caveat is the honest framing.

### 5.2 Modbus has no security (the core OT lesson)

Modbus/TCP is **plaintext and unauthenticated by design** — there is no
login, no integrity check, no encryption in the protocol. Any party that
can reach `:502` on `ot_zone` can:

- **Read** every register/coil (level, setpoints, pump/valve/alarm state).
- **Write** holding registers / coils — i.e. forge commands or falsify the
  process the HMI shows the operator.

Phase 1 **demonstrates** this rather than fixing it (fixing it is not how
real Modbus works — the lesson *is* the exposure). `docs/monitoring.md`
shows capturing this traffic in Wireshark and what normal vs. suspicious
looks like.

### 5.3 Output-register write semantics (Phase 1 empirical)

The §5.2 "Write holding registers / coils" line is honest about exposure
but coarse — a Phase 1 finding refines it.

**Output registers are reasserted every scan (architectural, not
authenticated).** OpenPLC writes HR0–HR2 (level + setpoints) from the
running program on every ~100 ms scan. An external write to one of these
registers is overwritten in ≤1 scan. Verified empirically: pymodbus
writing `95` to HR0 at 20 Hz for 3 seconds held the falsified value only
while the write loop ran; the natural cycle resumed within ~1 scan after
writes stopped, and the control logic (hysteresis on the in-PLC `Level`
variable) was never affected.

| Attacker action on `ot_zone` | Effect |
|---|---|
| Sustained writes to HR0–HR2 | HMI shows falsified values *while the attack runs*; PLC behaviour unchanged |
| Single/burst writes to HR0–HR2 | Overwritten ≤1 scan; HMI flickers at most |
| Writes to internal control state | Not exposed via Modbus — control logic runs against the in-PLC `Level`, not the published register |

**Scope honesty.** This covers only *output* registers (the PLC writes
them). Writes to **coils** (FC 5/15) and to registers the PLC consumes as
inputs (not used in this Phase 1 program, since the process is simulated
internally) are a different question and were not tested here — they
belong with Phase 2's attacker container exercises.

Refined framing: an attacker on `ot_zone` can **observe everything** and
can **falsify the HMI's view while actively writing**, but cannot
**redirect the PLC's control decisions** without compromising the PLC
program itself.

---

## 6. Attacker's view

| Attacker position | What they can do | Phase 1 verdict |
|---|---|---|
| In `attacker_zone` only | Nothing toward `ot_zone` — no route, cannot see Modbus | **Contained** (enforced boundary) |
| On `ot_zone` (already inside) | Full Modbus read/write — observe and forge the process | **Exposed by design** (the lesson) |
| On the Windows host | Reach 8080/1881/502; OpenPLC default creds unchanged | **Lab-local risk**, accepted scope |
| Container escape → host | Limited by no `--privileged`; not separately hardened | **Out of scope** Phase 1 |

The takeaway for a recruiter conversation: *the lab is honest about which
boundary it actually enforces (`attacker_zone`) versus which exposures it
deliberately demonstrates (Modbus on `ot_zone`) versus what it explicitly
defers (host/Docker hardening).* That honesty is the security maturity
signal, not a claim of total protection.

---

## 7. Phase 2 — where the security story goes next

Backlog tracked in `docs/MASTER.md`. Directly extends this document:

- Attacker container in `attacker_zone` → empirically test the §4 boundary.
- Suricata passive monitoring → detect the §5 Modbus abuse.
- Written attack scenarios → exercise the §6 attacker views end to end.
- Tighten `mgmt_zone`↔`ot_zone` so it becomes a real boundary, not soft.
