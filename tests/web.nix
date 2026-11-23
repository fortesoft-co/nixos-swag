# services.swag.web: a public vhost (local answer, tunnel ingress into
# nginx) and the client's address behind the tunnel: believed from the
# tunnel's side (loopback), ignored from anyone else. There is no network
# for ACME here; nginx serves the placeholder self-signed certificates
# NixOS creates before the first order.
{ pkgs, self }:
let
  # The backend: answers every request with the client headers nginx sent.
  echo = pkgs.writeText "echo.py" ''
    import http.server, json

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps({
                "real_ip": self.headers.get("X-Real-IP"),
                "forwarded_for": self.headers.get("X-Forwarded-For"),
                "proto": self.headers.get("X-Forwarded-Proto"),
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

    http.server.HTTPServer(("127.0.0.1", 8000), H).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "swag-web";

  nodes.server =
    { config, pkgs, ... }:
    {
      imports = [
        self.nixosModules.dns
        self.nixosModules.web
      ];

      environment.systemPackages = [ pkgs.curl pkgs.dnsutils ];

      systemd.services.echo = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -I ${echo}";
      };

      security.acme = {
        acceptTerms = true;
        defaults.email = "admin@example.com";
      };

      services.swag.dns = {
        enable = true;
        domain = "example.com";
        address = config.networking.primaryIPAddress;
        upstreamServers = [ "127.0.0.53" ];
      };

      services.swag.web = {
        enable = true;
        acme.dnsCredentials.CLOUDFLARE_DNS_API_TOKEN = "/run/dns-token";
        vhosts."app.example.com" = {
          port = 8000;
          public = true;
        };
        vhosts."lan-only.lan.example.com" = {
          port = 8000;
          tls = true;
        };
      };

      # A tunnel for the ingress to land in. It can't connect here; only its
      # configuration is checked.
      services.cloudflared = {
        enable = true;
        tunnels.server = {
          credentialsFile = "/dev/null";
          default = "http_status:404";
        };
      };
    };

  nodes.client =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.curl pkgs.dnsutils ];
    };

  testScript =
    { nodes, ... }:
    let
      server = nodes.server;
      ingress = server.services.cloudflared.tunnels.server.ingress;
      expected = {
        "app.example.com" = {
          service = "https://127.0.0.1:443";
          originRequest.originServerName = "app.example.com";
        };
      };
      # Only the fields this module sets; the type fills in the rest.
      ingressOk =
        builtins.attrNames ingress == [ "app.example.com" ]
        && ingress."app.example.com".service == expected."app.example.com".service
        && ingress."app.example.com".originRequest.originServerName == "app.example.com";
      serverIp = server.networking.primaryIPAddress;
    in
    assert ingressOk;
    assert server.services.swag.web.vhosts."app.example.com".tls;
    assert !server.services.swag.web.vhosts."lan-only.lan.example.com".public;
    ''
      import json

      start_all()
      server.wait_for_unit("dnsmasq.service")
      server.wait_for_unit("nginx.service")
      server.wait_for_unit("echo.service")
      server.wait_for_open_port(8000)
      server.wait_for_open_port(443)
      client.wait_for_unit("multi-user.target")

      def get(machine, name, *headers):
          h = " ".join(f"-H '{x}'" for x in headers)
          ip = "127.0.0.1" if machine is server else "${serverIp}"
          return json.loads(machine.succeed(
              f"curl -sfk --resolve {name}:443:{ip} {h} https://{name}/"
          ))

      with subtest("the public name is answered locally, and only locally"):
          out = client.succeed("dig +short @${serverIp} app.example.com").strip()
          assert out == "${serverIp}", out
          for rtype in ["AAAA", "HTTPS"]:
              out = client.succeed(f"dig +tries=1 +time=2 @${serverIp} app.example.com {rtype}")
              assert "status: NOERROR" in out and "ANSWER: 0" in out, out

      with subtest("a tunnel request carries the client's address to the backend"):
          r = get(server, "app.example.com", "CF-Connecting-IP: 203.0.113.7")
          assert r["real_ip"] == "203.0.113.7", r
          assert r["forwarded_for"].split(",")[-1].strip() == "203.0.113.7", r
          assert r["proto"] == "https", r
          server.succeed("grep -q '^203.0.113.7 ' /var/log/nginx/access.log")

      with subtest("a LAN client can't claim another address"):
          client_ip = "${nodes.client.networking.primaryIPAddress}"
          for name in ["app.example.com", "lan-only.lan.example.com"]:
              r = get(client, name, "CF-Connecting-IP: 203.0.113.9")
              assert r["real_ip"] == client_ip, r
              assert r["forwarded_for"].split(",")[-1].strip() == client_ip, r

      with subtest("public implies TLS: plain http redirects"):
          out = client.succeed(
              "curl -s -o /dev/null -w '%{http_code} %{redirect_url}'"
              " --resolve app.example.com:80:${serverIp} http://app.example.com/x"
          )
          assert out == "301 https://app.example.com/x", out
    '';
}
