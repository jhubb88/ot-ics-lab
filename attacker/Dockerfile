# =============================================================================
# Attacker container — Phase 2
# =============================================================================
#
# WHY THIS FILE EXISTS (same spirit as plc/Dockerfile — recruiter rationale):
#
# This container exists to PROBE the lab from attacker_zone. Pulling a
# pre-baked "pentest tools" image off Docker Hub (e.g. kalilinux/*) would
# undermine the same supply-chain stance Phase 1 takes for OpenPLC: trusting
# an anonymous publisher for an offensive-tooling image is exactly the kind
# of thing this lab is meant to teach you NOT to do.
#
# Instead: pinned Debian base, explicit `apt-get install` of named packages
# at build time, one pip-installed dependency with a pinned version. Every
# binary in this image is traceable to a named upstream.
#
# Convention match with plc/Dockerfile: pinned date-stamped Debian tag
# (Phase 1 stance is "pin tags for known images, pin commits when building
# from source"). The "-slim" suffix is Docker Hub's own naming for the
# minimal bookworm variant; the YYYYMMDD pattern matches Phase 1.
# =============================================================================

FROM debian:bookworm-20260518-slim

# Offensive + diagnostic tooling. All from Debian's main repo.
#   nmap            host/port discovery
#   tcpdump         packet capture from inside the container
#   curl            HTTP probing
#   dnsutils        provides `dig`
#   iputils-ping    provides `ping`
#   iproute2        provides `ip` (ip addr, ip route, ip neigh)
#   python3         runtime for pymodbus / scapy
#   python3-scapy   packet crafting (apt-managed where possible)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      nmap \
      tcpdump \
      curl \
      dnsutils \
      iputils-ping \
      iproute2 \
      python3 \
      python3-pip \
      python3-scapy \
 && rm -rf /var/lib/apt/lists/*

# pymodbus is not in Debian bookworm's apt repo — install pinned from PyPI.
# --break-system-packages is acceptable here: this container's only job is to
# be an attacker, there is no other system Python workload to protect.
RUN pip3 install --no-cache-dir --break-system-packages pymodbus==3.6.9

# No entrypoint that does work. Container sits idle until `docker exec`'d.
CMD ["sleep", "infinity"]
