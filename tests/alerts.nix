# services.swag.alerts: a failing unit sends one alert through Apprise and
# the command, failing again sends nothing, the first success says it
# recovered; scope "swag" leaves other units alone, scope "all" watches
# them; an alert that can't be sent is tried again on the next failure and
# never alerts about itself; the Apprise URLs (they carry a token) are on
# no command line and in no journal.
{ pkgs, self }:
let
  # Takes Apprise's json:// posts and keeps their bodies, one per line.
  receiver = pkgs.writeText "receiver.py" ''
    import http.server

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            with open("/tmp/received", "ab") as f:
                f.write(body.replace(b"\n", b" ") + b"\n")
            self.send_response(200)
            self.end_headers()

        def log_message(self, *args):
            pass

    http.server.HTTPServer(("127.0.0.1", 8000), H).serve_forever()
  '';

  flaky = name: {
    description = "A unit that fails while /run/${name}-fail exists";
    serviceConfig.Type = "oneshot";
    script = ''
      if [ -e /run/${name}-fail ]; then
        echo "${name}: failing on purpose"
        exit 1
      fi
    '';
  };

  common =
    { ... }:
    {
      imports = [ self.nixosModules.alerts ];

      systemd.services.test-secrets = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          install -d -m 0700 /run/test-secrets
          umask 077
          echo 'json://alerts:s3cr3t-token@127.0.0.1:8000/' > /run/test-secrets/alert-urls
        '';
      };
      systemd.services.receiver = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${receiver}";
      };
      systemd.services.swag-test-flaky = flaky "swag-test-flaky";
      systemd.services.plain-flaky = flaky "plain-flaky";

      services.swag.alerts = {
        enable = true;
        urlsFile = "/run/test-secrets/alert-urls";
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "swag-alerts";

  nodes.focused =
    { pkgs, ... }:
    {
      imports = [ common ];
      systemd.tmpfiles.rules = [ "d /var/lib/command-out 0700 swag-alerts swag-alerts -" ];
      services.swag.alerts = {
        command = "${pkgs.writeShellScript "keep" "cat >> /var/lib/command-out/events; echo >> /var/lib/command-out/events"}";
        serviceConfig.ReadWritePaths = [ "/var/lib/command-out" ];
      };
    };

  nodes.wide = {
    imports = [ common ];
    services.swag.alerts.scope = "all";
  };

  testScript = ''
    import json

    def received(m):
        out = m.succeed("cat /tmp/received 2>/dev/null || true")
        return [json.loads(l) for l in out.splitlines() if l.strip()]

    def events(m):
        out = m.succeed("cat /var/lib/command-out/events 2>/dev/null || true")
        return [json.loads(l) for l in out.splitlines() if l.strip()]

    def wait_received(m, n):
        m.wait_until_succeeds(f"test $(wc -l < /tmp/received) -ge {n}", timeout=60)
        got = received(m)
        assert len(got) == n, got
        return got

    start_all()
    for m in (focused, wide):
        m.wait_for_unit("multi-user.target")
        m.wait_for_unit("receiver.service")
        m.wait_for_unit("test-secrets.service")

    with subtest("a failing unit sends one alert, with its journal lines"):
        focused.succeed("touch /run/swag-test-flaky-fail")
        focused.fail("systemctl start swag-test-flaky")
        [alert] = wait_received(focused, 1)
        assert "swag-test-flaky.service failed" in alert["title"], alert
        assert "failing on purpose" in alert["message"], alert
        assert alert["type"] == "failure", alert
        focused.wait_until_succeeds("test $(grep -c . /var/lib/command-out/events) -eq 1")
        [ev] = events(focused)
        assert ev["event"] == "failed" and ev["unit"] == "swag-test-flaky.service", ev
        assert ev["host"] == "focused", ev
        assert any("failing on purpose" in l for l in ev["lines"]), ev

    with subtest("failing again sends nothing more"):
        focused.fail("systemctl start swag-test-flaky")
        focused.wait_until_succeeds(
            "journalctl -u swag-alert-failed@swag-test-flaky.service | grep -q 'already reported'"
        )
        assert len(received(focused)) == 1
        assert len(events(focused)) == 1

    with subtest("the first success says it recovered, later ones nothing"):
        focused.succeed("rm /run/swag-test-flaky-fail")
        focused.succeed("systemctl start swag-test-flaky")
        got = wait_received(focused, 2)
        assert "swag-test-flaky.service recovered" in got[1]["title"], got
        assert got[1]["type"] == "success", got
        focused.wait_until_succeeds("test $(grep -c . /var/lib/command-out/events) -eq 2")
        assert events(focused)[1]["event"] == "recovered"
        focused.succeed("systemctl start swag-test-flaky")
        focused.succeed("systemctl start swag-test-flaky")
        focused.succeed("test ! -e /run/swag-alerts/swag-test-flaky.service")
        assert len(received(focused)) == 2

    with subtest("scope swag watches the stack's units, not others"):
        out = focused.succeed("systemctl show -p OnFailure --value swag-test-flaky.service")
        assert "swag-alert-failed@swag-test-flaky.service" in out, out
        assert focused.succeed("systemctl show -p OnFailure --value plain-flaky.service").strip() == ""
        assert focused.succeed("systemctl show -p OnFailure --value receiver.service").strip() == ""

    with subtest("scope all watches every service, early-boot ones included"):
        assert "swag-alert-failed@receiver.service" in wide.succeed(
            "systemctl show -p OnFailure --value receiver.service"
        )
        # An early-boot oneshot that doesn't remain active: its OnSuccess
        # alert must not start it again.
        out = wide.succeed("systemctl show -p NRestarts -p Result -p ExecMainStartTimestampMonotonic suid-sgid-wrappers.service")
        assert "Result=success" in out, out
        wide.succeed("journalctl -b -u suid-sgid-wrappers.service | grep -c 'Starting Create SUID' | grep -qx 1")
        wide.fail("systemctl --failed --plain --no-legend | grep .")

    with subtest("an alert that can't be delivered yet is retried"):
        wide.succeed("systemctl stop receiver.service")
        wide.succeed("touch /run/plain-flaky-fail")
        wide.fail("systemctl start plain-flaky")
        wide.wait_until_succeeds(
            "journalctl -u swag-alert-failed@plain-flaky.service | grep -q 'trying again'"
        )
        wide.succeed("systemctl start receiver.service")
        [alert] = wait_received(wide, 1)
        assert "plain-flaky.service failed" in alert["title"], alert

    with subtest("an alert unit that fails sets off no other alert"):
        assert wide.succeed("systemctl show -p OnFailure --value swag-alert-failed@plain-flaky.service").strip() == ""
        assert wide.succeed("systemctl show -p OnSuccess --value swag-alert-ok@plain-flaky.service").strip() == ""
        wide.fail("systemctl list-units --all --plain --no-legend 'swag-alert-*@swag-alert-*' | grep .")

    with subtest("the Apprise URLs are on no command line and in no journal"):
        for m in (focused, wide):
            m.fail("journalctl -o cat | grep -F s3cr3t-token")
            m.fail("systemctl cat 'swag-alert-failed@x.service' | grep -F s3cr3t-token")
            m.fail("grep -rF s3cr3t-token /etc/systemd")
  '';
}
