# Auth-Dependency Outage Rehearsal (TACACS+/RADIUS/LDAP)

A step-by-step chaos scenario for answering one question: **when the auth
server your containers depend on goes dark, what actually happens?**

This doc implements the scenario proposed in
[issue #362](https://github.com/alexei-led/pumba/issues/362). It uses only
pumba's existing `iptables` port-scoped selectors and `netem` commands —
no hand-written iptables rules, no code changes.

## 1. The problem

Containerized workloads routinely depend on remote authentication:

- network automation and device-admin tooling speaking **TACACS+**
- VPN / 802.1X / NAC flows speaking **RADIUS**
- applications and CI runners binding to **LDAP / Active Directory**

Most teams *assume* an auth-server outage degrades gracefully: cached
credentials kick in, a local fallback account works, requests fail fast
with a clear error. In practice, outages reveal surprises:

- the app retries the dead server for 10 minutes before trying the fallback,
- the "local fallback" account was disabled by a provisioning script,
- a service **fails open** (grants access) when it was designed to **fail
  closed**, or vice versa,
- one container's auth library caches aggressively while another's doesn't,
  so behavior differs per workload.

A rehearsal turns these assumptions into evidence. Schedule it before you
need it — ideally before an audit, a migration, or an auth-server upgrade.

## 2. How pumba selects the traffic (read this first)

Pumba's `iptables` command installs rules on the **INPUT chain inside the
target container's network namespace** (`-I INPUT -i <iface> … -j DROP`,
see `pkg/chaos/iptables/loss.go`). That means its selectors match
**inbound** packets. To cut a container off from an auth server, you match
the **auth server's reply traffic** — its source IP and source port — not
your outbound packets:

| You want to match | Use | Example |
|---|---|---|
| replies from the auth server | `--source <auth-ip>` (CIDR notation) | `--source 10.0.5.10` |
| replies from a service port | `--src-port <port>` (comma-separated) | `--src-port 49` |

Every selector installs **its own rule** (OR semantics): `--source 10.0.5.10
--src-port 49` drops *all* packets from `10.0.5.10` **and** *all* packets
with source port 49, whichever matches first. If you want to scope tightly,
one selector is usually enough.

Flag placement matters: `--duration`, `--protocol`, `--source`,
`--destination`, `--src-port`, `--dst-port`, `--interface`, `--limit` all
live on the **`iptables` parent command**; the `loss` subcommand only takes
`--mode`, `--probability`, `--every`, `--packet`. `--duration` is
**required** — pumba refuses to run without it.

### Port reference

| Service | Protocol | Ports | Pumba flags |
|---|---|---|---|
| TACACS+ | TCP | 49 | `--protocol tcp --src-port 49` |
| RADIUS auth / accounting | UDP | 1812, 1813 | `--protocol udp --src-port 1812,1813` |
| LDAP | TCP | 389 | `--protocol tcp --src-port 389` |
| LDAPS | TCP | 636 | `--protocol tcp --src-port 636` |
| Kerberos (AD) | TCP and UDP | 88 | TCP: `--protocol tcp --src-port 88`; UDP: `--protocol udp --src-port 88` |
| kpasswd (AD) | TCP | 464 | `--protocol tcp --src-port 464` |
| Global Catalog (AD) | TCP | 3268 | `--protocol tcp --src-port 3268` |
| Global Catalog SSL (AD) | TCP | 3269 | `--protocol tcp --src-port 3269` |

## 3. Walkthrough: full blackhole

Replace the IPs with your auth servers and `re2:^web-` with your target
containers (names, or `re2:`-prefixed RE2 regexes).

**Step 0 — baseline.** Before breaking anything, record normal auth
behavior: median/p99 login latency, which credential path is used
(remote auth vs cache vs local fallback), and what the logs look like.
You need this to recognize "degraded".

**Step 1 — dry run.** Verify targeting without touching traffic:

```bash
pumba --dry-run iptables --duration 5m --protocol tcp \
  --source 10.0.5.10 --src-port 49 \
  loss --probability 1.0 re2:^web-
```

**Step 2 — TACACS+ blackhole.** Drop 100% of TACACS+ replies for 5 minutes:

```bash
pumba iptables --duration 5m --protocol tcp \
  --source 10.0.5.10 --src-port 49 \
  loss --probability 1.0 re2:^web-
```

**Step 3 — RADIUS blackhole** (auth + accounting, UDP):

```bash
pumba iptables --duration 5m --protocol udp \
  --source 10.0.5.11 --src-port 1812,1813 \
  loss --probability 1.0 re2:^vpn-gateway-
```

**Step 4 — LDAP/LDAPS blackhole:**

```bash
pumba iptables --duration 5m --protocol tcp \
  --source 10.0.5.12 --src-port 389,636 \
  loss --probability 1.0 re2:^app-
```

**Step 5 — Active Directory (Kerberos + Global Catalog).** Kerberos uses
both TCP and UDP on port 88, so run the two variants back to back:

```bash
pumba iptables --duration 5m --protocol tcp \
  --source 10.0.5.13 --src-port 88,464,3268,3269 \
  loss --probability 1.0 re2:^app-

pumba iptables --duration 5m --protocol udp \
  --source 10.0.5.13 --src-port 88 \
  loss --probability 1.0 re2:^app-
```

**Step 6 — partial outage.** A flapping server is nastier than a dead one.
Drop half the replies, or every 3rd packet:

```bash
pumba iptables --duration 5m --protocol tcp \
  --source 10.0.5.10 --src-port 49 \
  loss --probability 0.5 re2:^web-
```

During each run, exercise the workload the way users do: log in, rotate a
token, hit the endpoint that re-validates a session. Capture what happens.

## 4. Walkthrough: degraded path (netem)

A blackhole is binary. Real outages are often *slow*: congested links,
overloaded auth servers, cross-region latency spikes. Use `netem` for the
degraded variant. Note that `netem` has **no port selectors** — it shapes
all of the target container's traffic, so prefer a dedicated test instance
or accept the wider blast radius.

**Slow auth (2.5s delay + 500ms jitter):**

```bash
pumba --log-level=info netem --duration 5m \
  --tc-image ghcr.io/alexei-led/pumba-debian-nettools \
  delay --time 2500 --jitter 500 re2:^web-
```

**Flaky auth (50% loss):**

```bash
pumba --log-level=info netem --duration 5m \
  --tc-image ghcr.io/alexei-led/pumba-debian-nettools \
  loss --percent 50 re2:^web-
```

## 5. Observation checklist

For every run, fill in the expected-vs-actual table. "Expected" comes from
your runbook or architecture docs; "actual" from the rehearsal.

| # | Question | Expected | Actual |
|---|---|---|---|
| 1 | Time from first failed auth attempt to fallback engaged | | |
| 2 | Fallback path used (cached creds / local account / secondary server)? | | |
| 3 | Fail-open or fail-closed? (did unauthenticated requests get in?) | | |
| 4 | Auth latency p50/p99 during degradation | | |
| 5 | User-facing error message: clear ("auth server unreachable") or misleading? | | |
| 6 | Retries: bounded with backoff, or unbounded hammering of the dead server? | | |
| 7 | Recovery: after rules are removed, does auth resume without restarts? | | |
| 8 | Alarms: did monitoring fire, and was the alert actionable? | | |

What "good" looks like:

- fallback engages in **seconds, not minutes**, with bounded retries and
  backoff;
- the service **fails closed** (denies access) if that is the design — or
  fails open *only* where that was an explicit, documented decision;
- error messages name the cause ("authentication server unreachable"),
  not a generic 500;
- when the outage ends, the service recovers **without restarts**;
- an actionable alert fired within your SLO.

Anything else is a finding. File it, fix it, re-run the rehearsal.

## 6. Safety notes

- **Stage first.** Run the full rehearsal in a staging environment that
  mirrors production auth topology before touching anything shared.
- **`--dry-run` is free.** It logs the planned iptables commands without
  executing them. Use it every time you change selectors.
- **`--duration` is your dead-man's switch.** When it elapses, pumba
  issues the mirror `-D` command and removes the rules automatically —
  even on abort. Keep durations short (minutes) and prefer several short
  runs over one long one.
- **Limit blast radius.** Scope targets tightly (`re2:^staging-web-`,
  not `re2:.*`) and use `--limit` to cap how many matching containers get
  hit. Never run a blackhole against the auth server's own containers —
  that takes the service down for real.
- **Verify cleanup.** After each run, confirm the rules are gone inside a
  target container before the next run:

  ```bash
  docker exec <target-container> iptables -S INPUT
  ```

  The output should match your pre-run baseline (take a snapshot of it
  in Step 0). If a rule survived — e.g. pumba was killed ungracefully —
  remove it with the matching `iptables -D INPUT …` command shown by
  `--dry-run`.
- **Watch the auth server, not just the client.** An outage rehearsal can
  look like an attack from the server's side (connection storms on
  recovery). Coordinate with whoever owns the auth infrastructure.

## 7. Further reading

- [Network Chaos](network-chaos.md) — full `netem` / `iptables` reference
- [User Guide](guide.md) — targeting, `re2:` patterns, `--limit`, scheduling
- Executable version of this rehearsal: `../examples/auth_outage_rehearsal.sh`
