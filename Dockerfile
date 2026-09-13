# Tailscale subnet-router node for a Railway project.
# Joins the tailnet (userspace networking — Railway has no /dev/net/tun) and
# advertises the environment's private IPv6 network, so tailnet devices reach
# every service at <name>.railway.internal with no public exposure.
FROM debian:bookworm-slim

ARG TAILSCALE_VERSION=1.102.4
ARG COREDNS_VERSION=1.14.7

# iproute2: start.sh reads the route table to detect the private subnets.
# coredns: only used when TS_DNS_ALIAS_SUFFIX is set (DNS suffix aliasing).
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates iproute2 \
 && curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_amd64.tgz" \
    | tar -xz --strip-components=1 -C /usr/local/bin \
      "tailscale_${TAILSCALE_VERSION}_amd64/tailscale" \
      "tailscale_${TAILSCALE_VERSION}_amd64/tailscaled" \
 && curl -fsSL "https://github.com/coredns/coredns/releases/download/v${COREDNS_VERSION}/coredns_${COREDNS_VERSION}_linux_amd64.tgz" \
    | tar -xz -C /usr/local/bin coredns \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY start.sh ./
RUN chmod +x start.sh

CMD ["./start.sh"]
