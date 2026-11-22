# web

`nixosModules.web` · options under `services.swag.web`

nginx as a vhost registry. A service declares one entry (a name, a port,
`tls = true`) and gets a virtual host: reverse proxy with the recommended
headers, publicly trusted certificate, HTTP→HTTPS redirect, and the
firewall opened. Other modules add to the same entry (a login gate, extra
locations) without replacing it.

```nix
services.swag.web = {
  enable = true;
  acme.dnsCredentials.CLOUDFLARE_DNS_API_TOKEN = "/run/secrets/cloudflare-dns-token";
  vhosts."wiki.lan.example.com" = {
    port = 8080;
    tls = true;
  };
};

security.acme = {
  acceptTerms = true;
  defaults.email = "admin@example.com";
};
```

## Certificates

`tls = true` gets the vhost a Let's Encrypt certificate through the DNS-01
challenge: lego writes a TXT record in your DNS zone, so nothing has to be
reachable from the internet and LAN-only names work. nginx terminates TLS
on 443 and redirects 80 to it; the backend keeps receiving plain HTTP with
`X-Forwarded-Proto: https`.

`acme.dnsCredentials` maps the environment variables your lego DNS provider
expects to runtime files. Each reaches the ACME units as a systemd
credential (`<VAR>_FILE`), never the Nix store. For Cloudflare, a token
with *Zone › DNS › Edit* is enough:

| Provider | `dnsProvider` | `dnsCredentials` |
|---|---|---|
| Cloudflare, scoped token | `"cloudflare"` (default) | `CLOUDFLARE_DNS_API_TOKEN` |
| Cloudflare, global key | `"cloudflare"` | `CLOUDFLARE_API_KEY`, `CLOUDFLARE_EMAIL` |
| Anything else | [lego's provider id](https://go-acme.github.io/lego/dns/) | the variables its page lists |

A TLS vhost without credentials is refused at evaluation.

## Shaping a vhost

The root location (`/`) belongs to this module. Everything else goes
through typed options or one of the escape hatches:

```nix
services.swag.web.vhosts."chat.lan.example.com" = {
  port = 3000;
  tls = true;
  proxyWebsockets = true;                  # Upgrade headers on /
  extraLocations."/static/".alias = "/var/lib/chat/static/";
  rootExtraConfig = "client_max_body_size 50m;";
};
```

- **`scheme = "https"`** for a backend that only speaks HTTPS; its
  certificate isn't verified (typically self-signed on loopback).
- **`proxyHostHeader`** for a backend that rejects names other than its own
  bind address; the original name still goes in `X-Forwarded-Host`.
- **`basicAuthFile`** for a password prompt in front of the app: an
  htpasswd file readable by the nginx group.
- **`extraConfig`** and **`rootExtraConfig`** are raw nginx for the server
  block and the root location. Definitions from several modules are
  concatenated, which is how [authentik](authentik.md#apps-without-a-login)
  adds its `auth_request` gate to an app's vhost.

web knows no app. Glue for a specific app goes in that app's module.

## Options

| Option | Default | |
|---|---|---|
| `enable` | `false` | Run nginx with the recommended settings and the registry. |
| `openFirewall` | `true` | Open 80, and 443 when any vhost has TLS. |
| `acme` | `{ }` | DNS-01 settings for TLS vhosts. |
| `acme.dnsProvider` | `"cloudflare"` | lego DNS provider id. |
| `acme.dnsCredentials` | `{ }` | Env var → runtime file with the credential. |
| `vhosts` | `{ }` | Virtual hosts, keyed by server name. |
| `vhosts.<name>.host` | `"127.0.0.1"` | Backend host. |
| `vhosts.<name>.port` | required | Backend port. |
| `vhosts.<name>.scheme` | `"http"` | `"https"` for an HTTPS backend (not verified). |
| `vhosts.<name>.tls` | `false` | ACME certificate, 443, and a redirect from 80. |
| `vhosts.<name>.proxyWebsockets` | `false` | WebSocket upgrades on `/`. |
| `vhosts.<name>.proxyHostHeader` | `null` | Host header sent to the backend instead of the request's. |
| `vhosts.<name>.basicAuthFile` | `null` | htpasswd file (runtime path, nginx group) for basic auth. |
| `vhosts.<name>.extraLocations` | `{ }` | More locations, same shape as `services.nginx.virtualHosts.<name>.locations`. |
| `vhosts.<name>.extraConfig` | `""` | Raw nginx for the server block. |
| `vhosts.<name>.rootExtraConfig` | `""` | Raw nginx inside `/`. |
