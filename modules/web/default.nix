# Local web — shared nginx backbone + the subdomain port + vhost registry.
#
# Public vhosts (public = true) also get a local record from swag dns and an
# ingress entry on the host's Cloudflare tunnel, into nginx over HTTPS;
# realIp takes the client address from the tunnel's header, believed from
# loopback only.
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
  options,
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

  # Public vhosts: answered locally by swag dns (split horizon) and added to
  # the Cloudflare tunnel's ingress when this host runs one. The other
  # modules are optional: their options are only defined when they're
  # imported, hence the guards (on options, never config, so no recursion).
  publicVhosts = filterAttrs (_: v: v.public) cfg.vhosts;
  dnsDeclared = options.services ? swag.dns;
  hasDns = dnsDeclared && config.services.swag.dns.enable;
  hasTunnel = options.services ? cloudflared && config.services.cloudflared.enable;
  # nixos-cloudflared names the tunnel; without it, the host's name.
  tunnelName =
    if options.services ? cloudflared-tunnel && config.services.cloudflared-tunnel.enable then
      config.services.cloudflared-tunnel.name
    else
      config.networking.hostName;

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
        # The client's address from the tunnel's header, believed only from
        # the tunnel's side (loopback by default): a LAN client sending the
        # header keeps its own address. $remote_addr then carries it, so
        # logs and the X-Real-IP / X-Forwarded-For sent to backends do too.
        appendHttpConfig = optionalString (cfg.realIp.header != null) (
          concatMapStrings (p: "set_real_ip_from ${p};\n") cfg.realIp.trustedProxies
          + "real_ip_header ${cfg.realIp.header};\n"
        );
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
      networking.firewall.allowedTCPPorts = optionals cfg.openFirewall (
        [ 80 ] ++ optional (any (v: v.tls) (attrValues cfg.vhosts)) 443
      );
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

    # Public vhosts: the local answer and the tunnel's way in.
    (optionalAttrs dnsDeclared (mkIf (hasDns && publicVhosts != { }) {
      services.swag.dns.extraRecords = mapAttrs (
        _: _: mkDefault config.services.swag.dns.address
      ) publicVhosts;
    }))
    (mkIf (hasTunnel && publicVhosts != { }) {
      # Into nginx over HTTPS, with the vhost's name for SNI and the
      # certificate check, so the tunnel takes the same path as the LAN.
      services.cloudflared.tunnels.${tunnelName}.ingress = mapAttrs (name: _: {
        service = "https://127.0.0.1:443";
        originRequest.originServerName = name;
      }) publicVhosts;
    })

    {
      warnings = optional (publicVhosts != { } && !hasTunnel)
        "services.swag.web: ${concatStringsSep ", " (attrNames publicVhosts)} ${
          if length (attrNames publicVhosts) == 1 then "is" else "are"
        } public, but this host runs no Cloudflare tunnel (services.cloudflared), so no ingress is created: expose ${
          if length (attrNames publicVhosts) == 1 then "it" else "them"
        } yourself.";

      assertions = [
        {
          assertion = all (v: v.tls) (attrValues publicVhosts);
          message = "services.swag.web: public vhosts need tls (the tunnel reaches them over HTTPS): ${
            concatStringsSep ", " (attrNames (filterAttrs (_: v: !v.tls) publicVhosts))
          }.";
        }
        {
          assertion = !haveTlsVhosts || cfg.acme.dnsCredentials != { };
          message = "services.swag.web.vhosts.*.tls requires services.swag.web.acme.dnsCredentials (runtime files holding the DNS API credentials the cert's zone needs — for Cloudflare, CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL or a scoped CLOUDFLARE_DNS_API_TOKEN).";
        }
      ];
    }
  ]);
}