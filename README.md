# tailscale-rw

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/tailscale-subnet-router)

A Tailscale **subnet router** for a Railway project: deploy it as a service in any
Railway environment and every other service in that environment becomes reachable
from your tailnet under a project-scoped name — `postgres.myapp-production-railway.internal:5432`,
`http://my-api.myapp-production-railway.internal:8080`, any port, any protocol
(TCP *and* UDP) — **without exposing anything publicly**.

```
Mac ──tailnet──> tailscale-rw node ──forwards packets──> fd12:…::/64 (whole Railway env)
                       │
                       ├─ any <service>.<project>-<env>-railway.internal, any port
                       └─ split DNS: <project>-<env>-railway.internal → this node (CoreDNS → Railway's resolver)
```

The container runs `tailscaled` in userspace-networking mode (Railway provides no
`/dev/net/tun`) and advertises the environment's private subnets — the IPv6 `/64`,
plus the private IPv4 ranges in dual-stack environments (created after Oct 2025) —
which it detects at runtime from the route table — nothing is hardcoded, so the
same image works in any project/environment. New services are reachable the moment they
deploy; no per-service configuration.

## Environment variables (Railway service)

| Var | Value |
| --- | --- |
| `TAILSCALE_AUTHKEY` | **required** — reusable + ephemeral + pre-authorized key, tagged (e.g. `tag:railway`) |
| `TS_HOSTNAME` | tailnet hostname (default: the Railway **service name**, via `RAILWAY_SERVICE_NAME`) |
| `TS_EXIT_NODE` | boolean, default `false` — when `true`, also advertise this node as an **exit node** (route all client traffic through Railway) |
| `TS_EXTRA_ROUTES` | *(optional)* comma-separated extra CIDRs to advertise, if detection ever misses something |
| `TS_SKIP_ROUTES` | *(optional)* comma-separated CIDRs to NOT advertise — use to resolve cross-project route collisions (see Caveats) |
| `TS_DNS_ALIAS_SUFFIX` | project-specific DNS suffix (default: `<project>-<environment>-railway.internal`, via `RAILWAY_PROJECT_NAME`/`RAILWAY_ENVIRONMENT_NAME`). Set to `none` for plain `railway.internal` mode — see below |

`TAILSCALE_VERSION` and `COREDNS_VERSION` are Docker build args (pinned in the Dockerfile).

## Multiple Railway projects on one tailnet (`TS_DNS_ALIAS_SUFFIX`)

Every Railway environment serves the **same** `railway.internal` namespace and exposes
its resolver at the **same** `fd12::10`, so two projects can't share one split-DNS
entry (queries would race between resolvers, and the `fd12::10/128` host route would
fail over to a single project). To run a node per project:

1. Aliasing is the **default**: each node picks `<project>-<environment>-railway.internal`
   from `RAILWAY_PROJECT_NAME`/`RAILWAY_ENVIRONMENT_NAME` (override with
   `TS_DNS_ALIAS_SUFFIX`, or set it to `none` to disable). The node runs CoreDNS,
   which rewrites the alias suffix → `*.railway.internal`, resolves against *its
   own* environment, and rewrites the answers back.
2. Add split DNS in the admin console: `myapp-production-railway.internal` →
   **that node's tailnet IP** (printed in the boot summary).
3. Then: `psql -h postgres.myapp-production-railway.internal` reaches *that*
   project's DB — and the same project's staging node serves
   `postgres.myapp-staging-railway.internal`.

Caveats:
- An ephemeral node gets a new tailnet IP on each redeploy, which breaks the alias
  split-DNS entry — attach a **Railway volume at `/var/lib/tailscale`** on aliased
  nodes for a stable identity/IP (the boot summary always prints the current line).
- Only one node on the tailnet should advertise the plain `railway.internal` /
  `fd12::10/128` combo; aliased nodes still advertise their subnet routes (unique
  per environment), which is what makes their services reachable.

## One-time tailnet setup (admin console)

1. **Auth key** (Settings → Keys): *reusable*, *ephemeral*, *pre-authorized*, with a
   tag (e.g. `tag:railway`). Ephemeral means dead nodes vanish after redeploys.
2. **Route auto-approval** (Access Controls) — recommended. The node is ephemeral, so
   every redeploy registers a fresh node; without this you'd re-approve routes each time:

   ```jsonc
   "autoApprovers": {
     "routes": {
       "fd00::/8":    ["tag:railway"],
       "10.0.0.0/8":  ["tag:railway"]   // dual-stack (post-Oct-2025) environments
     },
     "exitNode": ["tag:railway"]   // only if you use TS_EXIT_NODE=true
   }
   ```

   (Alternative: attach a Railway volume at `/var/lib/tailscale` for a stable node
   identity and approve once by hand under Machines → node → Edit route settings.)
3. **Split DNS** (DNS → Nameservers → Add nameserver → Custom): the exact line is
   printed in the service's **boot summary** in the Railway deploy logs — by
   default `<project>-<env>-railway.internal` → the node's tailnet IP (or, in
   plain mode, `railway.internal` → Railway's resolver IP). MagicDNS must be on.
4. **ACLs**: your devices must be allowed to reach `tag:railway` (and the advertised
   `fd00::/8` destinations, if your ACLs are restrictive).

## Deploy on Railway

1. New service in the target project/environment → *GitHub repo* → this repo.
   **Do not add a public domain.** Private networking must be enabled (default).
2. Set `TAILSCALE_AUTHKEY` — that's the only required config; hostname and DNS
   alias default from Railway's injected service/project metadata.
3. Deploy, then read the boot summary in the logs — it prints the advertised
   routes and the exact split-DNS line to add.

## Use it

From any tailnet device (macOS: "Use Tailscale subnets" is on by default):

```sh
psql 'postgres://user:pw@postgres.myapp-production-railway.internal:5432/railway'
curl http://my-api.myapp-production-railway.internal:8080/health
```

Services stay password/auth-gated as before — the tailnet only provides the path.
Tighten further with Tailscale ACLs on `tag:railway` if needed.

As an exit node (`TS_EXIT_NODE=true` + approval): pick the node under
Exit Nodes on the client, and all your traffic egresses via Railway.

On macOS there's a companion **Raycast extension** in [`raycast/`](raycast/):
it lists every service in your routed environments and opens/copies its
private URL (host, port and connection string included).

## Caveats & known failure modes

- **Route collision / HA-flap between projects.** When two nodes advertise the
  *same* prefix, Tailscale treats them as a high-availability pair: one is
  primary, the other a standby that takes over if the primary goes offline.
  Each Railway environment's service subnet is a unique random `/64`, so those
  never collide — but environments can also carry **shared infra prefixes**
  (observed: `fd12:0:8::/64`, alongside an env-unique `/64` like
  `fd12:26cc:de40::/64`). If two projects' nodes both advertise such a prefix,
  traffic to it flows through whichever node is primary right now — and when
  that node restarts or redeploys, it silently fails over to the *other*
  project's node, which forwards it into its own environment, where those
  addresses mean something different (or nothing). The result is intermittent,
  restart-correlated weirdness that's painful to diagnose. Only the shared
  prefix is affected: services live in the env-unique subnets, each advertised
  by exactly one node, so skipping the shared prefix loses nothing.

  *Symptom:* everything in the env-unique `/64` works, but addresses in the
  shared prefix are intermittently unreachable or hit the wrong project —
  possibly flipping when a node restarts.

  *How to check:* from any device,
  `tailscale status --json | jq '.Peer[] | select(.Tags[]? == "tag:railway") | {HostName, PrimaryRoutes}'`
  — if the same prefix appears under two hostnames' advertised routes (or in the
  admin console → Machines → both nodes list it, one marked as the active
  route), you've got the collision.

  *Fix:* set `TS_SKIP_ROUTES=<the shared prefix>` on all but one node and
  redeploy. Service traffic is unaffected — services live in the env-unique
  `/64`. (This isn't skipped by default because the shared prefixes aren't
  documented or stable, and whether a prefix collides depends on what the
  *other* nodes on your tailnet advertise — something a single container can't
  know. On a one-project tailnet there is no collision and nothing to skip.)

- **Dual-stack environments: don't skip the IPv4 routes.** Environments created
  after Oct 2025 resolve service names to private IPv4 (`10.x`) **and** IPv6.
  Some services there only accept IPv4 — Railway's own database templates, for
  example, *accept* an IPv6 connection and then immediately reset it — and most
  clients try the A record first. The node advertises both families for this
  reason. Two consequences: IPv4 prefixes are likelier to collide across
  projects (same HA-flap as above → `TS_SKIP_ROUTES`), and if your LAN uses an
  overlapping `10.x` range, skip the offending route.

- **The resolver `/128` belongs to exactly one node.** Every environment exposes
  its DNS resolver at the *same* `fd12::10`. Only plain-mode nodes
  (`TS_DNS_ALIAS_SUFFIX=none`) advertise it; run at most one plain-mode node per
  tailnet, aliased nodes for everything else (aliased is the default).

- **Node identity is ephemeral without a volume.** No volume → new tailnet
  IP + machine name on every redeploy, which breaks the alias split-DNS entry
  (it points at the node's IP). Attach a volume at `/var/lib/tailscale`.

- **AutoApprovers silently no-op if the tag isn't declared.** `"autoApprovers"`
  referencing `tag:railway` does nothing unless `"tagOwners"` also declares
  `tag:railway`, and the node actually carries the tag (use a **tagged** auth
  key). Approval is evaluated when routes are advertised — after fixing ACLs,
  restart the service to re-trigger it.

- **First connection after a node (re)start can stall a few seconds** while NAT
  traversal upgrades from DERP relay to a direct path. Retry before debugging.

- **Throughput is modest.** Userspace `tailscaled` (netstack) tops out well
  below kernel WireGuard. Fine for psql/admin/dashboards; don't plan bulk data
  transfers through it.

## vs. tailscale-forwarder (TCP proxy approach)

[`brody192/tailscale-forwarder`](https://github.com/brody192/tailscale-forwarder)
solves an overlapping problem as an enumerated **TCP proxy**: the node listens on
ports you map (`CONNECTION_MAPPING_*`) and pipes each to one `host:port`, reached
as `<hostname>.<tailnet>.ts.net:<port>`. (This repo started as that
pattern — socat + `tailscale serve --tcp` — before becoming a subnet router.)

| | tailscale-forwarder | tailscale-rw (this) |
| --- | --- | --- |
| Coverage | only mapped ports | every service in the env, incl. future ones |
| Protocols | TCP only | TCP + UDP, any port |
| Naming | one hostname, made-up ports | real `<svc>.<project>-<env>-railway.internal` names |
| Tailnet admin setup | none (just an auth key) | one-time ACL (`tagOwners` + `autoApprovers`) + one split-DNS entry per project |
| TLS at the node | optional (Tailscale certs) | no (services speak their own protocol over the encrypted tunnel) |
| New service appears | edit mappings, redeploy | nothing to do |

Pick the forwarder to expose one or two TCP endpoints with zero tailnet admin
work; pick this to make whole projects reachable by real names, any protocol.

## Troubleshooting

- **Names under the alias suffix (or `*.railway.internal`) don't resolve** → split DNS not set (step 3) or MagicDNS off.
  Sanity-check the routed path first with a raw IPv6 from the boot summary.
- **Names resolve but connections hang** → routes not approved (step 2), or the
  client has subnet routes disabled.
- **One specific service doesn't resolve, others do** → its private DNS name is
  fixed at creation and does NOT follow a rename (and underscores in display
  names are never valid DNS). Check the service's `RAILWAY_PRIVATE_DOMAIN`
  variable — use the label in front of `.railway.internal` with your alias suffix.
- **Node missing from the tailnet** → check deploy logs; a missing/expired
  `TAILSCALE_AUTHKEY` prints an explicit error and exits after 30s.

## Outbound SOCKS connections

Set `TS_SOCKS5_SERVER=[::]:1055` to let services in this Railway environment
connect to tailnet hosts through a SOCKS5 proxy. It is disabled when unset.
Keep the listener private: do not attach a public domain or TCP proxy to it.
MongoDB's Java driver supports the `proxyHost` and `proxyPort` connection options;
use the database host's Tailscale IP and this service's Railway private hostname.
