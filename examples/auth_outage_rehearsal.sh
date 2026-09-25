#!/bin/sh
#
# auth_outage_rehearsal.sh - auth-dependency outage rehearsal runbook.
#
# Mirrors docs/auth-outage-rehearsal.md: blacks out the auth server's reply
# traffic to your containers with pumba's iptables selectors, then runs a
# degraded-path variant with netem delay/loss. No hand-written iptables
# rules needed - --source already exists on the iptables command.
#
# Auth and login checks run WHILE each chaos phase is active: pumba starts
# in the background, you exercise logins during that window, then the phase
# is stopped (pumba removes its rules on stop/abort; SIGTERM triggers the
# abort path). Nothing is exercised after the phase ends - post-phase
# checks can only see the recovered state.
#
# Gating: the script aborts unless the dry run succeeds AND you type an
# explicit 'yes' confirmation. A failed read (stdin exhausted/redirected)
# also aborts - no disruption happens without interactive approval.
#
# All knobs are environment variables:
#
#   AUTH_IP     IP of the auth server (TACACS+/RADIUS/LDAP/AD)
#   AUTH_PROTO  tcp for TACACS+/LDAP/AD, udp for RADIUS        (default: tcp)
#   AUTH_PORTS  comma-separated service ports, for reference    (default: 49)
#               TACACS+ 49 | RADIUS 1812,1813 | LDAP 389,636
#               AD Kerberos 88 | kpasswd 464 | GC 3268,3269
#               Shown in the plan line only: the runs scope with --source
#               alone, because every selector installs its own DROP rule
#               (OR semantics) - stacking --source with --src-port would
#               widen the blast radius, not narrow it.
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

abort() {
  echo "aborting: $1" >&2
  exit 1
}

# stop_phase <pid>: end a backgrounded pumba run; pumba removes its
# rules/qdisc on stop (SIGTERM -> abort path -> cleanup).
stop_phase() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

echo "Rehearsal plan: drop ${AUTH_PROTO}/${AUTH_PORTS} replies from ${AUTH_IP}"
echo "  against containers: ${TARGET}, ${DURATION} per phase"
echo ""

# Phase 0: dry run - verify targeting without touching traffic.
# A failed dry run, a failed read, or a declined confirmation aborts
# everything before any disruption starts.
pumba --dry-run iptables --duration "$DURATION" --protocol "$AUTH_PROTO" \
  --source "$AUTH_IP" \
  loss --probability 1.0 "$TARGET" || abort "dry run failed - refusing to disrupt traffic"

echo "Type 'yes' to ARM the real blackhole (anything else aborts)"
read -r reply || abort "no confirmation received (stdin not interactive?)"
[ "$reply" = "yes" ] || abort "not confirmed"

# Phase 1: full blackhole - drop 100% of the auth server's reply packets.
# NOTE: pumba installs rules on the INPUT chain inside the target container,
# so --source selects the auth server's *replies*, which is what makes the
# dependency look unreachable to the container. A single selector only:
# --source and --src-port would each install their own DROP rule.
pumba --log-level=info iptables --duration "$DURATION" --protocol "$AUTH_PROTO" \
  --source "$AUTH_IP" \
  loss --probability 1.0 "$TARGET" &
PUMBA_PID=$!
sleep 5

echo ""
echo "Blackhole is ACTIVE. Exercise logins NOW, while the rules are in place:"
echo "  - fresh login, token rotation, session re-validation"
echo "Press enter when done (phase ends on its own after ${DURATION})"
if ! read -r _; then
  stop_phase "$PUMBA_PID"
  abort "lost input - phase stopped"
fi
stop_phase "$PUMBA_PID"

echo "Blackhole phase done. Verify cleanup inside a target container:"
echo "  docker exec <target-container> iptables -S INPUT"

echo ""
echo "Type 'yes' for the degraded-path variant (slow auth), anything else stops here"
read -r reply || abort "no confirmation received - stopping"
[ "$reply" = "yes" ] || abort "not confirmed"

# Phase 2: degraded path - 2.5s delay + 500ms jitter.
# --target/--ingress-port scope the delay to traffic bound for the auth
# server (egress filters; inbound replies can't be selected by netem).
pumba --log-level=info netem --duration "$DURATION" --tc-image "$TC_IMAGE" \
  --target "$AUTH_IP" --ingress-port "$AUTH_PORTS" \
  delay --time 2500 --jitter 500 "$TARGET" &
PUMBA_PID=$!
sleep 5

echo ""
echo "Slow-auth phase is ACTIVE. Exercise logins NOW, while the delay applies:"
echo "  - note p50/p99 latency, timeouts, fallback behavior"
echo "Press enter when done (phase ends on its own after ${DURATION})"
if ! read -r _; then
  stop_phase "$PUMBA_PID"
  abort "lost input - phase stopped"
fi
stop_phase "$PUMBA_PID"

echo ""
echo "Type 'yes' for the flaky-auth variant (50% loss), anything else stops here"
read -r reply || abort "no confirmation received - stopping"
[ "$reply" = "yes" ] || abort "not confirmed"

# Phase 3: degraded path - 50% packet loss, scoped to auth-bound traffic
pumba --log-level=info netem --duration "$DURATION" --tc-image "$TC_IMAGE" \
  --target "$AUTH_IP" --ingress-port "$AUTH_PORTS" \
  loss --percent 50 "$TARGET" &
PUMBA_PID=$!
sleep 5

echo ""
echo "Flaky-auth phase is ACTIVE. Exercise logins NOW, while the loss applies:"
echo "  - retries bounded with backoff, or unbounded hammering?"
echo "Press enter when done (phase ends on its own after ${DURATION})"
if ! read -r _; then
  stop_phase "$PUMBA_PID"
  abort "lost input - phase stopped"
fi
stop_phase "$PUMBA_PID"

echo ""
echo "Rehearsal complete. Post-run checks:"
echo "  1. iptables rules removed?  docker exec <target> iptables -S INPUT"
echo "  2. auth recovered without restarts? try a fresh login"
echo "  3. fill in docs/auth-outage-rehearsal.md section 5 (expected vs actual)"
