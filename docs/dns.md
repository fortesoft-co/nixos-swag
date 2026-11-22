# dns

`nixosModules.dns` · options under `services.swag.dns`

A dnsmasq resolver for your LAN. It answers an internal zone under a domain
you own (`lan.example.com` for `example.com`) with this host's address,
wildcard included, and forwards everything else upstream. Every service on
the host gets a name with no per-service record: `wiki.lan.example.com`,
`auth.lan.example.com`, anything you register with [web](web.md).

```nix
services.swag.dns = {
  enable = true;
  domain = "example.com";            # a domain you own
  address = "192.168.1.10";          # this host on the LAN
  upstreamServers = [ "192.168.1.1" "9.9.9.9" ];
};
```

Then point your network at it: set this host as the DNS server your router
hands out over DHCP. That step lives on the router, not in NixOS.

## Why a domain you own

The internal zone is `<label>.<domain>`. Using a real domain, rather than a
made-up TLD or `.local`, keeps two doors open:

- **Real certificates for LAN names.** [web](web.md) gets publicly trusted
  certificates for `*.lan.example.com` through DNS-01, with no private CA
  to install on every device.
- **One name inside and out.** A name can be answered here on the LAN and
  through a tunnel from outside, without renaming anything.

Avoid `.local`: macOS and systemd-resolved send it to mDNS first, and
unicast names under it resolve unreliably.

## Local answers for other names

`extraRecords` adds A records: other hosts on the LAN that don't run DNS
themselves, or a public name you want answered locally.

```nix
services.swag.dns.extraRecords = {
  "printer.lan.example.com" = "192.168.1.50";
};
```

A name answered here is answered *only* here: its other record types (AAAA,
HTTPS, MX) come back empty instead of from the public zone. That is on
purpose. A public name kept on the LAN would otherwise mix the local A
record with the public IPv6 and HTTPS records and send browsers elsewhere.
[authentik](authentik.md#going-public) uses this for its public login.

## With the other modules

- **web and directory and authentik** derive their default names from
  `internalDomain`: `ldap.lan.example.com`, `auth.lan.example.com`.
- **This host** resolves its own zone too: `useAsHostResolver` points
  `networking.nameservers` at 127.0.0.1 (with `mkForce`). dnsmasq ignores
  `/etc/resolv.conf`, so there is no loop.

## Options

| Option | Default | |
|---|---|---|
| `enable` | `false` | Run dnsmasq with the internal zone. |
| `domain` | `"example.com"` | Your apex domain. The default is a documentation placeholder; set it. |
| `label` | `"lan"` | Label before the domain: the zone is `<label>.<domain>`. |
| `internalDomain` | read-only | `<label>.<domain>`, for other modules and your config. Set even when dns is off. |
| `address` | `"127.0.0.1"` | IPv4 the zone and every name under it resolve to: this host's LAN address. |
| `upstreamServers` | required | Resolvers for everything else. Without them nothing outside the zone resolves. |
| `extraRecords` | `{ }` | Full name → IPv4. Each name, and its subdomains, is answered only here. |
| `useAsHostResolver` | `true` | Point this host's own resolver at dnsmasq. |
| `openFirewall` | `true` | Open port 53 (TCP and UDP). |
