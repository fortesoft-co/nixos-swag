{
  lib,
  ...
}:
with lib;
let
  inherit (import ../../lib/types.nix { inherit lib; }) secretPath;
in
{
  options.services.swag.web = {
    enable = mkEnableOption "the shared nginx web backbone (subdomain port 80)";

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open the firewall for port 80, and 443 when any vhost has tls, so
        LAN/VPN clients reach subdomain vhosts by name. Defaults to true —
        the module owns the shared HTTP(S) ports.
      '';
    };

    # ── ACME: DNS-01 certificates for TLS vhosts ────────────────────────────
    acme = mkOption {
      type = types.submodule {
        options = {
          dnsProvider = mkOption {
            type = types.str;
            default = "cloudflare";
            description = ''
              lego DNS provider id used for ACME DNS-01 challenges (the
              security.acme.certs dnsProvider value). "cloudflare" covers any
              zone with DNS on Cloudflare, including the internal
              "*.lan.<domain>" names (they live in the real zone's TXT space).
            '';
          };
          dnsCredentials = mkOption {
            type = types.attrsOf secretPath;
            default = { };
            example = literalExpression ''
              {
                CLOUDFLARE_DNS_API_TOKEN = config.age.secrets.dns-token.path;
              }
            '';
            description = ''
              DNS API credentials for answering DNS-01 challenges, keyed by
              the env var name lego's DNS provider expects; each value is
              the runtime path of a file holding the raw credential. The
              acme units read each file through systemd credentials
              (<VAR>_FILE) at issuance and renewal. For cloudflare: a scoped API token
              maps to CLOUDFLARE_DNS_API_TOKEN, the global key to
              CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL. Empty = no TLS vhost
              may be declared on this host.
            '';
          };
        };
      };
      default = { };
      description = "ACME/DNS-01 settings for the TLS vhost registry.";
    };

    # ── The client's address behind a tunnel ─────────────────────────────────
    realIp = mkOption {
      type = types.submodule {
        options = {
          header = mkOption {
            type = types.nullOr types.str;
            default = "CF-Connecting-IP";
            description = ''
              Request header holding the client's address, set by the tunnel
              or proxy in front of nginx. Cloudflare's tunnel sets
              CF-Connecting-IP and overwrites any value a client sends.
              nginx takes the client address from it ($remote_addr, so
              access logs, X-Real-IP and X-Forwarded-For to the backend)
              only for requests from `trustedProxies`; anyone else's header
              is ignored. null = always use the connection's address.
            '';
          };
          trustedProxies = mkOption {
            type = types.listOf types.str;
            default = [
              "127.0.0.1"
              "::1"
            ];
            description = ''
              Addresses (or CIDR ranges) whose `header` is believed: where
              the tunnel or proxy connects to nginx from. Loopback by
              default, for a tunnel daemon on this host.
            '';
          };
        };
      };
      default = { };
      description = "Where nginx learns the client's address behind a tunnel.";
    };

    vhosts = mkOption {
      type = types.attrsOf (
        types.submodule ({ config, ... }: {
          options = {
            host = mkOption {
              type = types.str;
              default = "127.0.0.1";
              description = "Backend host to proxy to (the proxyPass target host).";
            };
            port = mkOption {
              type = types.port;
              description = "Backend port to proxy to (the proxyPass target port).";
            };

            # ── Generic escape hatches (no app-specific knowledge here) ────────
            scheme = mkOption {
              type = types.enum [ "http" "https" ];
              default = "http";
              description = ''
                Upstream scheme for the root proxyPass. "https" fronts an
                HTTPS upstream (e.g. authentik on :9443); the module then emits
                `proxy_ssl_verify off` on the root location so a self-signed /
                internal upstream cert is accepted. Use the `extraLocations`
                escape hatch to add any per-location ssl bits for non-root
                locations you add.
              '';
            };

            extraLocations = mkOption {
              type = types.attrsOf types.attrs;
              default = { };
              description = ''
                Extra nginx location blocks merged into this vhost's
                `locations`, keyed by location string (e.g. "/static/",
                "/ws/"). Values are location-config attrsets (proxyPass,
                alias, proxyWebsockets, extraConfig, ...) — the same shape as
                `services.nginx.virtualHosts.<name>.locations.<path>`. Lets an
                app module add its own locations (static assets, websockets,
                auth callbacks) through the registry without localweb knowing
                why. The root "/" location is owned by this module and should
                not be overridden here.
              '';
            };

            extraConfig = mkOption {
              type = types.lines;
              default = "";
              description = ''
                Raw nginx config appended to the vhost's server block
                (services.nginx.virtualHosts.<name>.extraConfig). Use for ad
                hoc server-level directives none of the typed options cover.
                Definitions from several modules are concatenated.
              '';
            };

            rootExtraConfig = mkOption {
              type = types.lines;
              default = "";
              example = "auth_request /auth;";
              description = ''
                Raw nginx directives added inside the root "/" location,
                which this module owns. Lets another module gate or adjust
                the root proxy (e.g. an auth_request subrequest) without
                replacing it. Definitions from several modules are
                concatenated.
              '';
            };

            basicAuthFile = mkOption {
              type = types.nullOr secretPath;
              default = null;
              description = ''
                Runtime path to an htpasswd file for HTTP basic auth on this
                vhost. null = no auth. nginx workers read it at request time,
                so it must be readable by the nginx group (e.g. agenix
                `group = "nginx"`). Generate it with e.g.
                `htpasswd -cB htpasswd <user>`; it must never be in the Nix
                store.
              '';
            };

            proxyHostHeader = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Override the Host header sent to the backend. When null, the
                default $host (the incoming request hostname) is used. Set to
                e.g. "localhost" for backends that validate the Host header
                against their bind address and reject external hostnames —
                nginx still sends X-Forwarded-Host with the original hostname
                (via recommendedProxySettings) so the backend can generate
                correct redirect URLs.
              '';
            };

            proxyWebsockets = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Enable WebSocket proxying on the root location. Adds
                proxy_set_header Upgrade and Connection upgrade headers,
                overriding the recommendedProxySettings Connection "" that
                would otherwise prevent WebSocket upgrades. Set to true for
                apps that use WebSockets (e.g. chat, live dashboards).
              '';
            };

            public = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Reachable from the internet under the same name (split
                horizon). Implies `tls`. With swag dns on this host, the name
                is answered locally with this host, so LAN clients come
                straight here; with a Cloudflare tunnel on this host
                (services.cloudflared), the tunnel gets an ingress entry for
                it, pointed at nginx over HTTPS, and nixos-cloudflared adds
                the public DNS record. Without a tunnel, exposing it is up to
                you (a warning says so). Put a login in front of anything
                that doesn't have one (services.swag.authentik.apps).
              '';
            };

            tls = mkOption {
              type = types.bool;
              default = config.public;
              defaultText = literalExpression "config.public";
              description = ''
                Terminate TLS with an ACME-issued certificate for this vhost's
                server_name. Requires services.swag.web.acme.dnsCredentials
                (the DNS API credentials for the zone) and
                security.acme.acceptTerms. nginx
                serves :443 ssl and the :80 vhost 301s to https; the backend
                still receives plain http with X-Forwarded-Proto=https.
                Apps whose prod-mode cookies are forced Secure (outline)
                require this. The cert is publicly trusted (Let's Encrypt
                via DNS-01), so no CA distribution is needed on clients.
              '';
            };
          };
        })
      );
      default = { };
      description = ''
        Subdomain vhosts, keyed by server_name — the nginx analog of
        cloudflared's ingress map. Service modules register their web UI here
        (one entry: backend host + port) and this module emits the nginx
        virtualHost (listen on 80, proxyPass, recommended proxy settings) and
        opens the firewall. Requires the host to run swag dns for the
        server_name to resolve on the LAN. Set basicAuthFile for a vhost that
        must be password-gated (e.g. a public-domain vhost fronting cloudflared).
        Use scheme/extraLocations/extraConfig for backends that need more than a
        plain HTTP root proxy (HTTPS upstreams, static assets, websockets).
      '';
    };
  };
}