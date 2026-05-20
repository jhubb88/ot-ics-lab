# =============================================================================
# OpenPLC v3 — built from PINNED official upstream source
# =============================================================================
#
# WHY THIS FILE EXISTS (recruiter-facing rationale — DO NOT delete this comment):
#
# There is NO official prebuilt OpenPLC image on Docker Hub. Every prebuilt
# OpenPLC image is community-maintained with unverified provenance. For an
# OT/ICS *security* lab, pulling an unvetted third-party PLC image would
# directly contradict the entire point of the project.
#
# So this lab builds the PLC from the official upstream repository
# (github.com/thiagoralves/OpenPLC_v3), pinned to one immutable commit:
#   - The exact source can be inspected before it runs (supply-chain control)
#   - The build is reproducible (pinned commit, not a moving branch tip)
#   - No trust is placed in an anonymous Docker Hub publisher
#
# This same reasoning is repeated in README.md and docs/network-security.md
# on purpose — the "why" is part of the security story, not just plumbing.
#
# NOTE: OpenPLC v3 is upstream end-of-life (a v4 exists). v3 remains the
# de facto standard for labs of this type and is intentional for Phase 1.
# Migrating to v4 is tracked in docs/MASTER.md as a Phase 2 backlog item.
# =============================================================================

# Base image matches upstream's own Dockerfile base, pinned by tag (CC choice:
# pinned tag, never "latest", for reproducibility).
FROM debian:trixie-20251020

# >>> SUPPLY-CHAIN CONTROL POINT <<<
# Pinned upstream commit (verified HEAD of master on 2026-04-04). To update
# OpenPLC later, change ONLY this value to a new, reviewed commit SHA.
ARG OPENPLC_COMMIT=b5d41356dab4aeadca0dd7ca64ba542f870b595d

# Tooling needed only to fetch + build upstream. ca-certificates is required
# for the HTTPS git clone to succeed on a minimal base image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

# Clone, then HARD-pin to the reviewed commit. Build fails loudly if the
# commit can't be checked out — we never silently fall back to a branch tip.
RUN git clone https://github.com/thiagoralves/OpenPLC_v3.git \
 && cd OpenPLC_v3 \
 && git checkout "${OPENPLC_COMMIT}" \
 && git rev-parse HEAD

WORKDIR /opt/OpenPLC_v3

# Official documented container install path. The "docker" argument tells
# upstream's installer to skip sudo/privilege-escalation steps (per upstream
# README). This compiles the runtime and provisions the web stack.
RUN ./install.sh docker

# PORT DOCUMENTATION — KNOWN GOTCHA: these are TWO DIFFERENT ports.
#   8080  -> OpenPLC web editor / management UI   (browser, human-facing)
#   502   -> Modbus/TCP server                    (machine-facing; FUXA talks here)
# EXPOSE is documentation only; docker-compose.yml controls real exposure.
EXPOSE 8080 502

# Official upstream entrypoint — starts the OpenPLC runtime + web server.
ENTRYPOINT ["./start_openplc.sh"]
