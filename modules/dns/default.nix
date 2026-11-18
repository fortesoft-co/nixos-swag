# Local DNS (dnsmasq) — split-horizon zone for *.<internalDomain> → host IP.
#
# Serves a wildcard A record so every vhost server_name under the internal
# zone resolves to this host without per-service DNS records — the standard
# building block for subdomain-based access to local web services. Non-local
# queries are forwarded to upstreamServers, so upstream resolution is
# unchanged. The host's own
# resolver can optionally be repointed at the local dnsmasq (useAsHostResolver)
# so the host resolves its own zone.
#
# For LAN clients to use this resolver, the network's DHCP DNS must point at
# this host — that step is environment-specific (router/gateway config) and
# belongs in the host config, not this module.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
with lib;
let
  cfg = config.services.swag.dns;
in
{
  imports = [ ./options.nix ];

  config = mkMerge [
    # Computed read-only value, set unconditionally so other modules and the
    # host can reference config.services.swag.dns.internalDomain even when disabled.
    { services.swag.dns.internalDomain = "${cfg.label}.${cfg.domain}"; }

    (mkIf cfg.enable {
      services.dnsmasq = {
        enable = true;
        settings = {
          # Hygiene: don't forward bare hostnames or RFC1918 reverse lookups.
          domain-needed = true;
          bogus-priv = true;

          # Only use the explicit `server=` lines below, not /etc/resolv.conf —
          # avoids a loop when useAsHostResolver repoints the host to 127.0.0.1.
          no-resolv = true;

          # Every name answered here is local: queries for it are never
          # forwarded, so record types not set here (AAAA, HTTPS, MX, …) get
          # an empty answer instead of the public zone's. A public name kept
          # on the LAN would otherwise mix its local A record with the
          # public AAAA and HTTPS records (a CDN's IPv6 addresses, ECH and
          # HTTP/3 hints) and send browsers elsewhere.
          local = map (name: "/${name}/") ([ cfg.internalDomain ] ++ attrNames cfg.extraRecords);

          # Wildcard: *.internalDomain AND internalDomain → address.
          address =
            [ "/${cfg.internalDomain}/${cfg.address}" ]
            ++ (mapAttrsToList (name: ip: "/${name}/${ip}") cfg.extraRecords);

          # Upstream forwarders for everything outside the internal zone.
          server = cfg.upstreamServers;
        };
      };

      # Repoint the host's own resolver at the local dnsmasq so the host
      # resolves its own internal zone. mkForce wins over a plain
      # `networking.nameservers = [...]` elsewhere (priority 100).
      # dnsmasq forwards non-local queries to the original upstreams, so nothing
      # is lost.
      networking.nameservers = mkIf cfg.useAsHostResolver (mkForce [ "127.0.0.1" ]);

      networking.firewall = mkIf cfg.openFirewall {
        allowedUDPPorts = [ 53 ];
        allowedTCPPorts = [ 53 ];
      };
    })
  ];
}