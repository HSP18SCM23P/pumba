#!/bin/sh
#
# auth_outage_rehearsal.sh - auth-dependency outage rehearsal runbook.
#
# Mirrors docs/auth-outage-rehearsal.md: blacks out the auth server's reply
# traffic to your containers with pumba's iptables selectors, then runs a
# degraded-path variant with netem delay/loss. No hand-written iptables
# rules needed - --src-port/--source already exist on the iptables command.
#
# All knobs are environment variables:
#
#   AUTH_IP     IP of the auth server (TACACS+/RADIUS/LDAP/AD)
#   AUTH_PROTO  tcp for TACACS+/LDAP/AD, udp for RADIUS        (default: tcp)
#   AUTH_PORTS  comma-separated service ports                   (default: 49)
#               TACACS+ 49 | RADIUS 1812,1813 | LDAP 389,636
#               AD Kerberos 88 | kpasswd 464 | GC 3268,3269
#   TARGET      target containers (name or re2: regex)           (default: re2:^web-)
#   DURATION    how long each chaos phase lasts                   (default: 5m)
#   TC_IMAGE    netem sidecar image                               (default: ghcr.io/alexei-led/pumba-debian-nettools)
#
# Example: rehearse a RADIUS outage against the VPN gateway containers:
#   AUTH_IP=10.0.5.11 AUTH_PROTO=udp AUTH_PORTS=1812,1813 TARGET=re2:^vpn-gateway- ./auth_outage_rehearsal.sh

set -o xtrace

AUTH_IP="${AUTH_IP:-10.0.5.10}"
AUTH_PROTO="${AUTH_PROTO:-tcp}"
AUTH_PORTS="${AUTH_PORTS:-49}"
TARGET="${TARGET:-re2:^web-}"
DURATION="${DURATION:-5m}"
TC_IMAGE="${TC_IMAGE:-ghcr.io/alexei-led/pumba-debian-nettools}"

echo "Rehearsal plan: drop ${AUTH_PROTO}/${AUTH_PORTS} replies from ${AUTH_IP}"
echo "  against containers: ${TARGET}, ${DURATION} per phase"
echo ""

# Phase 0: dry run - verify targeting without touching traffic
pumba --dry-run iptables --duration "$DURATION" --protocol "$AUTH_PROTO" \
  --source "$AUTH_IP" --src-port "$AUTH_PORTS" \
  loss --probability 1.0 "$TARGET"

read -p "Dry run looked right? Press enter to ARM the real blackhole (Ctrl-C to abort)"

# Phase 1: full blackhole - drop 100% of the auth server's reply packets.
# NOTE: pumba installs rules on the INPUT chain inside the target container,
# so --source/--src-port select the auth server's *replies*, which is what
# makes the dependency look unreachable to the container.
pumba --log-level=info iptables --duration "$DURATION" --protocol "$AUTH_PROTO" \
  --source "$AUTH_IP" --src-port "$AUTH_PORTS" \
  loss --probability 1.0 "$TARGET"

echo "Blackhole phase done. Exercise logins now, then verify cleanup:"
echo "  docker exec <target-container> iptables -S INPUT"

read -p "Press enter for the degraded-path variant (slow auth) or Ctrl-C to stop"

# Phase 2: degraded path - 2.5s delay + 500ms jitter on all container traffic.
# netem has no port selectors, so prefer a dedicated test instance here.
pumba --log-level=info netem --duration "$DURATION" --tc-image "$TC_IMAGE" \
  delay --time 2500 --jitter 500 "$TARGET"

read -p "Press enter for the flaky-auth variant (50% loss) or Ctrl-C to stop"

# Phase 3: degraded path - 50% packet loss
pumba --log-level=info netem --duration "$DURATION" --tc-image "$TC_IMAGE" \
  loss --percent 50 "$TARGET"

echo ""
echo "Rehearsal complete. Post-run checks:"
echo "  1. iptables rules removed?  docker exec <target> iptables -S INPUT"
echo "  2. auth recovered without restarts? try a fresh login"
echo "  3. fill in docs/auth-outage-rehearsal.md section 5 (expected vs actual)"
