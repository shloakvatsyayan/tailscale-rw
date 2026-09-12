#!/usr/bin/env bash
# Join the tailnet as a subnet router for this Railway environment's private
# network (userspace networking — Railway has no /dev/net/tun), so tailnet
# devices reach every service directly at <service>.railway.internal.
# Nothing is exposed on Railway's public proxy.
set -euo pipefail

if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
  echo "TAILSCALE_AUTHKEY is not set — cannot join the tailnet. Set it on the service, then redeploy." >&2
  # Back off so a missing key is a slow, obvious wait rather than a tight crash-loop.
  sleep 30
  exit 1
fi

# DNS-safe label: lowercase, alnum + hyphen only.
sanitize() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'; }

# Defaults derive from Railway's injected metadata: the tailnet hostname is the
# service name, and the DNS alias suffix is <project>-<environment>-railway.internal
# (environment included so prod/staging nodes of one project get distinct
# suffixes), so a fresh deploy needs no TS_* config at all.
# TS_DNS_ALIAS_SUFFIX=none opts out of aliasing (plain railway.internal mode,
# resolver /128 advertised).
HOSTNAME_TS="$(sanitize "${TS_HOSTNAME:-${RAILWAY_SERVICE_NAME:-tailscale-rw}}")"

ALIAS_SUFFIX="${TS_DNS_ALIAS_SUFFIX:-}"
if [ -z "$ALIAS_SUFFIX" ] && [ -n "${RAILWAY_PROJECT_NAME:-}" ]; then
  ALIAS_SUFFIX="$(sanitize "$RAILWAY_PROJECT_NAME")"
  if [ -n "${RAILWAY_ENVIRONMENT_NAME:-}" ]; then
    ALIAS_SUFFIX="${ALIAS_SUFFIX}-$(sanitize "$RAILWAY_ENVIRONMENT_NAME")"
  fi
  ALIAS_SUFFIX="${ALIAS_SUFFIX}-railway.internal"
fi
case "$ALIAS_SUFFIX" in none|off|false) ALIAS_SUFFIX="" ;; esac

mkdir -p /var/run/tailscale /var/lib/tailscale

tailscaled \
  --tun=userspace-networking \
  --socks5-server="${TS_SOCKS5_SERVER:-}" \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/var/run/tailscale/tailscaled.sock &
TAILSCALED_PID=$!

ts() { tailscale --socket=/var/run/tailscale/tailscaled.sock "$@"; }

# --- Detect this environment's private subnets --------------------------------
# The kernel route table already holds the connected networks in network form,
# so no address arithmetic is needed. Railway private networking is ULA IPv6
# (fd00::/8); environments created after 2025-10 are dual-stack and add private
# IPv4 (10.x) — some services there (e.g. Railway's database templates) only
# accept IPv4, and clients prefer A records, so both families are advertised.
ROUTES=()
while IFS= read -r net; do
  ROUTES+=("$net")
done < <(
  {
    ip -6 route show | awk '$1 ~ /^fd/ && $1 ~ /\// {print $1}'
    ip -4 route show | awk '($1 ~ /^10\./ || $1 ~ /^172\.(1[6-9]|2[0-9]|3[01])\./ || $1 ~ /^192\.168\./) && $1 ~ /\// {print $1}'
  } | sort -u
)

# Railway's internal DNS resolver may live outside the connected subnets —
# advertise it as a host route so tailnet split DNS can reach it (overlap is
# harmless). Skip that advertisement on aliased nodes: every environment exposes
# the SAME resolver address (fd12::10), so a second node advertising it would
# fail over with the first; the alias's CoreDNS reaches the resolver locally.
DNS_INT=()
DNS_OTHER=()
while IFS= read -r ns; do
  case "$ns" in
    fd*)
      [ -z "$ALIAS_SUFFIX" ] && ROUTES+=("${ns}/128")
      DNS_INT+=("$ns")
      ;;
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*)
      [ -z "$ALIAS_SUFFIX" ] && ROUTES+=("${ns}/32")
      DNS_INT+=("$ns")
      ;;
    *) DNS_OTHER+=("$ns") ;;
  esac
done < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf)

# Escape hatch for anything detection misses (comma-separated CIDRs).
if [ -n "${TS_EXTRA_ROUTES:-}" ]; then
  IFS=',' read -ra EXTRA <<< "$TS_EXTRA_ROUTES"
  ROUTES+=("${EXTRA[@]}")
fi

# Drop routes that would collide with another node on the tailnet (two nodes
# advertising the SAME prefix become an HA pair — only one carries traffic).
# Railway envs may share infra prefixes (e.g. fd12:0:8::/64) on top of the
# env-unique /64; skip those here rather than flap. Comma-separated CIDRs.
if [ -n "${TS_SKIP_ROUTES:-}" ]; then
  FILTERED=()
  for net in "${ROUTES[@]}"; do
    case ",${TS_SKIP_ROUTES}," in
      *",${net},"*) echo "skipping route ${net} (TS_SKIP_ROUTES)" ;;
      *) FILTERED+=("$net") ;;
    esac
  done
  ROUTES=("${FILTERED[@]-}")
fi

ROUTES_CSV=""
if [ "${#ROUTES[@]}" -gt 0 ]; then
  ROUTES_CSV=$(IFS=,; echo "${ROUTES[*]}")
else
  echo "WARNING: no private subnets detected — joining as a plain node (no routes advertised)." >&2
fi

UP_FLAGS=(
  --authkey="${TAILSCALE_AUTHKEY}"
  --hostname="${HOSTNAME_TS}"
  --advertise-routes="${ROUTES_CSV}"
  --accept-dns=false
  --accept-routes=false
)
# Optional: also offer this node as an exit node (clients can route ALL their
# traffic through Railway). Needs admin approval, like subnet routes.
if [ "${TS_EXIT_NODE:-false}" = "true" ]; then
  UP_FLAGS+=(--advertise-exit-node)
fi

until ts up "${UP_FLAGS[@]}"; do
  echo "waiting for tailscaled..."
  sleep 1
done

# --- Optional DNS suffix alias -------------------------------------------------
# Every Railway environment serves the same `railway.internal` namespace, so two
# projects can't share one tailnet split-DNS entry. TS_DNS_ALIAS_SUFFIX gives this
# project its own suffix (e.g. myapp-production-railway.internal): CoreDNS rewrites it to
# railway.internal, forwards to this environment's resolver, and rewrites answers
# back. Point tailnet split DNS for the alias suffix at THIS node's tailnet IP.
COREDNS_PID=""
if [ -n "$ALIAS_SUFFIX" ]; then
  if [ "${#DNS_INT[@]}" -eq 0 ]; then
    echo "WARNING: DNS alias ${ALIAS_SUFFIX} requested but no private-network resolver found — alias disabled." >&2
  else
    cat > /app/Corefile <<EOF
${ALIAS_SUFFIX}:53 {
    errors
    cache 30
    rewrite stop {
        name suffix ${ALIAS_SUFFIX}. railway.internal.
        answer auto
    }
    forward . ${DNS_INT[*]}
}
EOF
    coredns -conf /app/Corefile &
    COREDNS_PID=$!
  fi
fi

# --- Boot summary: everything the one-time tailnet setup needs ----------------
echo "=================================================================="
echo "${HOSTNAME_TS} is on the tailnet ($(ts ip -4 2>/dev/null | head -1 || true))"
echo "  advertised routes: ${ROUTES_CSV:-none}"
echo "  exit node:         ${TS_EXIT_NODE:-false}"
echo ""
echo "One-time tailnet setup (admin console), if not done yet:"
echo "  1. Approve the advertised routes (Machines -> ${HOSTNAME_TS}), or add an"
echo "     autoApprover so redeploys of this ephemeral node never need re-approval:"
echo '       "autoApprovers": {"routes": {"fd00::/8": ["tag:railway"]}}'
if [ -n "$COREDNS_PID" ]; then
  echo "  2. DNS alias active — split DNS for the alias points at THIS node:"
  echo "       ${ALIAS_SUFFIX} -> $(ts ip -4 2>/dev/null | head -1)"
  echo "     NOTE: an ephemeral node gets a fresh tailnet IP on redeploy, which breaks"
  echo "     this entry. Attach a Railway volume at /var/lib/tailscale for a stable IP."
elif [ "${#DNS_INT[@]}" -gt 0 ]; then
  echo "  2. Split DNS (DNS -> Nameservers -> Custom, restrict to search domain):"
  for ns in "${DNS_INT[@]}"; do
    echo "       railway.internal -> ${ns}"
  done
else
  echo "  2. WARNING: no private-network resolver in /etc/resolv.conf (found: ${DNS_OTHER[*]:-none})."
  echo "     Split DNS cannot point at a loopback/link-local resolver; reach services"
  echo "     by their private IPv6 address instead."
fi
echo "=================================================================="

# Tie the container to its daemons: if either dies, exit so Railway restarts us.
if [ -n "$COREDNS_PID" ]; then
  wait -n "$TAILSCALED_PID" "$COREDNS_PID"
else
  wait "$TAILSCALED_PID"
fi
