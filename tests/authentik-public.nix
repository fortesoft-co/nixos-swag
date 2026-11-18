# services.swag.authentik.dashboard.publicDomain + mfa: one login hostname
# inside and out, the admin interface refused to tunnel requests, the local
# name redirecting to the public one, and a second factor demanded at login.
# There is no network for ACME here; nginx serves the placeholder
# self-signed certificates NixOS creates before the first order.
{ pkgs, self }:
let
  # Logs in through the default flow's executor API and prints the
  # component of the stage that follows the password.
  afterPassword = pkgs.writeText "after-password.py" ''
    import http.cookiejar, json, ssl, sys, urllib.request

    base, user, password = sys.argv[1:4]
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar), urllib.request.HTTPSHandler(context=ctx)
    )
    api = base + "/api/v3/flows/executor/default-authentication-flow/?query="

    def call(data=None):
        headers = {"Content-Type": "application/json"}
        csrf = next((c.value for c in jar if c.name == "authentik_csrf"), None)
        if csrf:
            headers["X-authentik-CSRF"] = csrf
        body = json.dumps(data).encode() if data is not None else None
        with opener.open(urllib.request.Request(api, data=body, headers=headers)) as r:
            return json.load(r)

    ch = call()
    assert ch["component"] == "ak-stage-identification", ch
    ch = call({"component": ch["component"], "uid_field": user})
    if ch["component"] == "ak-stage-password":
        ch = call({"component": ch["component"], "password": password})
    print(json.dumps(ch))
  '';
in
pkgs.testers.runNixOSTest {
  name = "swag-authentik-public";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        self.nixosModules.dns
        self.nixosModules.web
        self.nixosModules.authentik
      ];

      virtualisation.memorySize = 6144;
      virtualisation.cores = 4;
      virtualisation.diskSize = 4096;

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
        pkgs.dnsutils
      ];

      systemd.services.test-secrets = {
        wantedBy = [ "multi-user.target" ];
        before = [ "authentik-secrets.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0700 /run/test-secrets
          umask 077
          echo 'test-secret-key-0123456789abcdef0123456789abcdef' > /run/test-secrets/ak-secret
          echo 'akadmin-password-1' > /run/test-secrets/ak-admin
          echo 'test-api-token-0123456789' > /run/test-secrets/ak-token
          echo 'unused' > /run/test-secrets/dns-token
        '';
      };
      systemd.services.authentik-secrets.requires = [ "test-secrets.service" ];

      security.acme = {
        acceptTerms = true;
        defaults.email = "admin@example.com";
      };

      services.swag.dns = {
        enable = true;
        domain = "example.com";
        label = "lan";
        address = "127.0.0.1";
        upstreamServers = [ "127.0.0.53" ];
      };

      services.swag.web = {
        enable = true;
        acme.dnsProvider = "cloudflare";
        acme.dnsCredentials.CF_DNS_API_TOKEN = "/run/test-secrets/dns-token";
      };

      services.swag.authentik = {
        enable = true;
        secrets.AUTHENTIK_SECRET_KEY = "/run/test-secrets/ak-secret";
        bootstrap = {
          email = "admin@example.com";
          passwordFile = "/run/test-secrets/ak-admin";
          tokenFile = "/run/test-secrets/ak-token";
        };
        dashboard.tls = true;
        dashboard.publicDomain = "auth.example.com";
        mfa.enforce = true;
      };
    };

  testScript = ''
    import json

    api = "http://127.0.0.1:9000/api/v3"
    auth = "-H 'Authorization: Bearer test-api-token-0123456789'"
    public = "curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' --resolve auth.example.com:443:127.0.0.1 --resolve auth.lan.example.com:443:127.0.0.1"
    tunnel = "-H 'CF-Connecting-IP: 203.0.113.7'"

    machine.wait_for_unit("dnsmasq.service")
    machine.wait_for_unit("nginx.service")
    machine.wait_for_unit("authentik.service")
    machine.wait_for_open_port(9000, timeout=600)
    machine.wait_until_succeeds(
        f"curl -sf {auth} '{api}/stages/authenticator/validate/?name=default-authentication-mfa-validation'"
        " | jq -e '.results[0].not_configured_action == \"configure\"'",
        timeout=600,
    )

    with subtest("the public name resolves locally"):
        assert machine.succeed("dig +short @127.0.0.1 auth.example.com").strip() == "127.0.0.1"

    with subtest("login is served on the public name, the admin interface only off the tunnel"):
        flow = "https://auth.example.com/if/flow/default-authentication-flow/"
        admin = "https://auth.example.com/if/admin/"
        assert machine.succeed(f"{public} {flow}").startswith("200"), "login page not served"
        assert machine.succeed(f"{public} {tunnel} {flow}").startswith("200"), "login page blocked on the tunnel"
        assert not machine.succeed(f"{public} {admin}").startswith("403"), "admin blocked on the LAN"
        assert machine.succeed(f"{public} {tunnel} {admin}").startswith("403"), "admin reachable through the tunnel"

    with subtest("the local name redirects to the public one"):
        out = machine.succeed(f"{public} https://auth.lan.example.com/if/flow/x/?a=1")
        assert out == "301 https://auth.example.com/if/flow/x/?a=1", out

    with subtest("the MFA stage demands a webauthn or totp factor"):
        st = json.loads(machine.succeed(
            f"curl -sf {auth} '{api}/stages/authenticator/validate/?name=default-authentication-mfa-validation'"
        ))["results"][0]
        assert sorted(st["device_classes"]) == ["static", "totp", "webauthn"], st
        assert len(st["configuration_stages"]) == 2, st

    with subtest("a login without a factor is sent to enrollment"):
        ch = json.loads(machine.succeed(
            "${pkgs.python3}/bin/python3 -I ${afterPassword} http://127.0.0.1:9000 akadmin akadmin-password-1"
            " 2>&1 || true"
        ).strip().splitlines()[-1])
        assert ch["component"] == "ak-stage-authenticator-validate", ch
        assert len(ch.get("configuration_stages", [])) == 2, ch
  '';
}
