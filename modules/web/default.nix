# Local web — shared nginx backbone + the subdomain port + vhost registry.
#
# Centralizes nginx enable + recommended settings + ACME, and provides
# services.swag.web.vhosts — a server_name → { host, port, scheme?, extraLocations?,
# extraConfig?, basicAuthFile? } map (the nginx analog of cloudflared's ingress)
# so service modules register a subdomain + backend in one entry and this module
# emits the listen/proxyPass/auth/firewall plumbing. Opens port 80 so vhosts are
# reachable on the LAN by name.
#
# The escape hatches (scheme, extraLocations, extraConfig) keep this module
# context-generic: an app that needs an HTTPS upstream (authentik on :9443),
# static assets (/static/), or websockets (/ws/) supplies those via the registry
# entry — web doesn't need to know about authentik. Composes with
# swag dns (dnsmasq resolves *.<internalDomain> → this host) and cloudflared
# (public domain ingress). A vhost with a basicAuthFile is password-gated by an
# htpasswd file the host provides at runtime.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.swag.web;

  # Vhosts terminating TLS (server_name → tls bool true), and the ACME cert
  # attrkey for a vhost (dots → dashes, so cert names stay valid unit-name
  # components).
  tlsVhosts = filterAttrs (_: v: v.tls) cfg.vhosts;
  haveTlsVhosts = tlsVhosts != { };
  certName = name: builtins.replaceStrings [ "." ] [ "-" ] name;

  # Root "/" location for a vhost: proxyPass to the backend, recommended proxy
  # headers, and proxy_ssl_verify off when the upstream speaks HTTPS (self-signed
  # / internal certs — e.g. authentik on :9443). The root location is owned by
  # this module; app-specific extra locations go in `extraLocations`, and
  # directives for the root location itself in `rootExtraConfig`.
  rootLocation = v:
    let
      parts =
        (optional (v.scheme == "https") "proxy_ssl_verify off;")
        ++ (optional (v.rootExtraConfig != "") v.rootExtraConfig)
        ++ (optional (v.proxyHostHeader != null) ''
          proxy_set_header Host ${v.proxyHostHeader};
          proxy_set_header Origin http://${v.proxyHostHeader};
        '');
    in
    {
      proxyPass = "${v.scheme}://${v.host}:${toString v.port}";
      recommendedProxySettings = true;
    }
    // optionalAttrs (v.proxyWebsockets) {
      proxyWebsockets = true;
    }
    // optionalAttrs (parts != [ ]) {
      extraConfig = concatStringsSep "\n" parts;
    };

in
{
  imports = [ ./options.nix ];

  config = mkIf cfg.enable (mkMerge [
    {
      services.nginx = {
        enable = true;
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
      };

            # One virtualHost per registered vhost on the shared subdomain port 80
      # (server_name routing). basicAuthFile, when set, is the host's runtime
      # htpasswd file, read by the nginx worker.
      # scheme/extraLocations/extraConfig are passed through verbatim — this
      # module stays generic, app-specific nginx lives in the registering module.
      services.nginx.virtualHosts = mapAttrs (name: v:
        let
          # TLS vhosts: nginx terminates :443 with the ACME cert while the
          # backend keeps receiving plain http — X-Forwarded-Proto
          # (recommendedProxySettings emits $scheme) then reads https
          # downstream, which app's with prod-mode forced-Secure cookies
          # (outline) require. :80 forceSSLs so plain-http navigations land
          # on TLS; DNS-01 renewal never needs :80, so the redirect can't
          # break ACME either.
          listen = if v.tls then [
            { addr = "0.0.0.0"; port = 80; }
            { addr = "0.0.0.0"; port = 443; ssl = true; }
          ] else [ { addr = "0.0.0.0"; port = 80; } ];
        in
        ({
          inherit listen;
          locations = { "/" = rootLocation v; } // v.extraLocations;
        }
        // optionalAttrs v.tls {
          useACMEHost = certName name;
          forceSSL = true;
        }
        // optionalAttrs (v.extraConfig != "") { extraConfig = v.extraConfig; }
        // optionalAttrs (v.basicAuthFile != null) {
          inherit (v) basicAuthFile;
        })
      ) cfg.vhosts;

      # Shared subdomain port — every vhost is reachable by name once open.
      networking.firewall.allowedTCPPorts = optional cfg.openFirewall 80;
    }

    # ACME DNS-01 certificates for TLS vhosts. DNS-01 only writes TXT records
    # in the DNS zone — the origin keeps plain http, so these certs never
    # interact with Cloudflare-tunnelled public origins (no double-TLS, no
    # origin-vs-edge mismatch). Credential wiring goes through systemd's
    # credential indirection (this channel's security.acme renamed
    # credentialsFile → credentialFiles, whose keys must be <VAR>_FILE/
    # <VAR>_PATH): each dnsCredentials entry maps the env var name lego's DNS
    # provider expects (e.g. CLOUDFLARE_API_KEY) to a runtime file, bound as
    # <VAR>_FILE for the acme units — the acme service resolves the file
    # content into <VAR> itself.
    (mkIf haveTlsVhosts {
      security.acme.certs = mapAttrs' (name: v:
        nameValuePair (certName name) {
          domain = name;
          dnsProvider = cfg.acme.dnsProvider;
          credentialFiles = mapAttrs' (envVar: path:
            nameValuePair "${envVar}_FILE" path
          ) cfg.acme.dnsCredentials;
          group = "nginx";
          reloadServices = [ "nginx" ];
        }) tlsVhosts;

      networking.firewall.allowedTCPPorts = [ 443 ];
    })

    {
      assertions = [
        {
          assertion = !haveTlsVhosts || cfg.acme.dnsCredentials != { };
          message = "services.swag.web.vhosts.*.tls requires services.swag.web.acme.dnsCredentials (runtime files holding the DNS API credentials the cert's zone needs — for Cloudflare, CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL or a scoped CLOUDFLARE_DNS_API_TOKEN).";
        }
      ];
    }
  ]);
}