# services.swag.authentik.enrollment: an invitation creates the account in
# the directory (not in Authentik) with the invitation's groups, the account
# syncs into Authentik and can log in; logins outside the access group are
# held for approval; the directory's enrollment socket refuses other users
# and groups it may not grant; no password reaches a command line or log.
{ pkgs, self }:
let
  # Drives Authentik's flow executor API like the browser does.
  #   flow.py BASE enroll SLUG ITOKEN|- USERNAME NAME EMAIL PASSWORD
  #     submits the enrollment form and prints the challenge that follows
  #   flow.py BASE login USERNAME PASSWORD
  #     logs in through the default flow and prints the challenge after
  #     the password
  flowDriver = pkgs.writeText "flow.py" ''
    import http.cookiejar, json, sys, urllib.parse, urllib.request

    base, mode = sys.argv[1:3]
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    def call(api, data=None):
        headers = {"Content-Type": "application/json"}
        csrf = next((c.value for c in jar if c.name == "authentik_csrf"), None)
        if csrf:
            headers["X-authentik-CSRF"] = csrf
        body = json.dumps(data).encode() if data is not None else None
        with opener.open(urllib.request.Request(api, data=body, headers=headers)) as r:
            return json.load(r)

    if mode == "enroll":
        slug, itoken, username, name, email, password = sys.argv[3:9]
        query = "" if itoken == "-" else urllib.parse.quote("itoken=" + itoken)
        api = f"{base}/api/v3/flows/executor/{slug}/?query={query}"
        ch = call(api)
        if ch["component"] == "ak-stage-prompt":
            ch = call(api, {
                "component": "ak-stage-prompt",
                "username": username, "name": name, "email": email,
                "password": password, "password_repeat": password,
            })
    else:
        username, password = sys.argv[3:5]
        api = f"{base}/api/v3/flows/executor/default-authentication-flow/?query="
        ch = call(api)
        ch = call(api, {"component": ch["component"], "uid_field": username})
        if ch["component"] == "ak-stage-password":
            ch = call(api, {"component": ch["component"], "password": password})
    print(json.dumps(ch))
  '';

  # Talks to the enrollment socket directly, as the flow's policies do.
  socketClient = pkgs.writeText "enroll-client.py" ''
    import json, socket, sys
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect("/run/swag-directory-enroll.sock")
    s.sendall(sys.stdin.buffer.read())
    print(s.makefile().readline().strip())
  '';
in
pkgs.testers.runNixOSTest {
  name = "swag-authentik-enrollment";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        self.nixosModules.directory
        self.nixosModules.authentik
      ];

      virtualisation.memorySize = 6144;
      virtualisation.cores = 4;
      virtualisation.diskSize = 4096;

      environment.systemPackages = [
        pkgs.openldap
        pkgs.curl
        pkgs.jq
      ];

      systemd.services.test-secrets = {
        wantedBy = [ "multi-user.target" ];
        before = [
          "lldap.service"
          "swag-directory-provision.service"
          "authentik-secrets.service"
          "authentik-directory-source-setup.service"
        ];
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0700 /run/test-secrets
          umask 077
          echo 'admin-password-1' > /run/test-secrets/lldap-admin
          echo 'alice-initial-pw' > /run/test-secrets/alice
          echo 'bind-password-xyz' > /run/test-secrets/bind
          echo 'test-secret-key-0123456789abcdef0123456789abcdef' > /run/test-secrets/ak-secret
          echo 'akadmin-password-1' > /run/test-secrets/ak-admin
          echo 'test-api-token-0123456789' > /run/test-secrets/ak-token
        '';
      };
      systemd.services.lldap.requires = [ "test-secrets.service" ];
      systemd.services.authentik-secrets.requires = [ "test-secrets.service" ];

      services.swag.directory = {
        enable = true;
        baseDn = "dc=example,dc=com";
        adminPasswordFile = "/run/test-secrets/lldap-admin";
        groups.git-users = { };
        groups.staff = { };
        # alice exists but isn't in the access group: her login waits.
        users.alice = {
          email = "alice@example.com";
          displayName = "Alice";
          initialPasswordFile = "/run/test-secrets/alice";
        };
      };

      services.swag.authentik = {
        enable = true;
        secrets.AUTHENTIK_SECRET_KEY = "/run/test-secrets/ak-secret";
        bootstrap = {
          email = "admin@example.com";
          passwordFile = "/run/test-secrets/ak-admin";
          tokenFile = "/run/test-secrets/ak-token";
        };
        directorySource = {
          enable = true;
          bindPasswordFile = "/run/test-secrets/bind";
        };
        enrollment = {
          enable = true;
          grantableGroups = [ "git-users" ];
        };
      };
    };

  testScript = ''
    import json

    api = "http://127.0.0.1:9000/api/v3"
    auth = "-H 'Authorization: Bearer test-api-token-0123456789'"
    ldap = "-x -H ldap://127.0.0.1:3890"
    base_dn = "dc=example,dc=com"
    flow = "${pkgs.python3}/bin/python3 -I ${flowDriver} http://127.0.0.1:9000"
    bob_pw = "bob-chosen-password-1"

    def get(path):
        return json.loads(machine.succeed(f"curl -sf {auth} '{api}{path}'"))

    def post(path, data):
        return json.loads(machine.succeed(
            f"curl -sf {auth} -X POST -H 'Content-Type: application/json'"
            f" -d '{json.dumps(data)}' '{api}{path}'"
        ))

    def run_flow(*args):
        quoted = " ".join("'" + a + "'" for a in args)
        return json.loads(machine.succeed(f"{flow} {quoted}").strip().splitlines()[-1])

    def invite(name, groups):
        flow_pk = get("/flows/instances/?slug=swag-enrollment")["results"][0]["pk"]
        return post("/stages/invitation/invitations/", {
            "name": name, "single_use": True, "flow": flow_pk,
            "fixed_data": {"groups": groups},
        })["pk"]

    def groups_of(user):
        out = machine.succeed(
            f"ldapsearch {ldap} -D uid=admin,ou=people,{base_dn} -w admin-password-1"
            f" -b ou=groups,{base_dn} '(member=uid={user},ou=people,{base_dn})' cn"
        )
        return sorted(l.split(": ", 1)[1] for l in out.splitlines() if l.startswith("cn: "))

    machine.wait_for_unit("swag-directory-provision.service")
    machine.wait_for_unit("authentik.service")
    machine.wait_for_open_port(9000, timeout=600)
    machine.wait_for_unit("authentik-directory-source-setup.service", timeout=600)
    try:
        machine.wait_until_succeeds(
            f"curl -sf {auth} '{api}/flows/instances/?slug=swag-enrollment' | jq -e '.results | length == 1'",
            timeout=180,
        )
    except Exception:
        machine.succeed("sed 's/--pty/--wait --pipe/' $(command -v ak) > /tmp/ak-pipe && chmod +x /tmp/ak-pipe")
        print(machine.execute(
            "/tmp/ak-pipe shell -c '"
            "from authentik.blueprints.models import BlueprintInstance\n"
            "from authentik.blueprints.v1.importer import Importer\n"
            "valid, logs = Importer.from_string(BlueprintInstance(path=\"swag-enrollment.yaml\").retrieve()).validate()\n"
            "print(\"VALID\", valid)\n"
            "[print(\"BPLOG\", l) for l in logs]\n"
            "' 2>&1 | grep -E 'VALID|BPLOG|Error|error' | tail -40",
            timeout=300,
        )[1])
        raise
    machine.wait_until_succeeds(
        f"curl -sf {auth} '{api}/core/users/?username=alice' | jq -e '.results | length == 1'",
        timeout=600,
    )

    with subtest("without an invitation the flow is closed"):
        ch = run_flow("enroll", "swag-enrollment", "-", "mallory", "M", "m@example.com", "mallory-password-1")
        assert ch["component"] == "ak-stage-access-denied", ch

    with subtest("the form reports a taken username and a short password, and creates nothing"):
        token = invite("bob-invite", ["git-users"])
        ch = run_flow("enroll", "swag-enrollment", token, "alice", "Bob", "bob@example.com", bob_pw)
        assert ch["component"] == "ak-stage-prompt" and ch.get("response_errors"), ch
        # The invitation was spent on that visit; use a fresh one.
        token = invite("bob-invite-2", ["git-users"])
        ch = run_flow("enroll", "swag-enrollment", token, "bob", "Bob", "bob@example.com", "short")
        assert ch["component"] == "ak-stage-prompt" and "12 characters" in json.dumps(ch["response_errors"]), ch
        machine.fail(f"ldapwhoami {ldap} -D uid=bob,ou=people,{base_dn} -w short")

    with subtest("an invitation creates the account in the directory, with its groups"):
        token = invite("bob-invite-3", ["git-users"])
        ch = run_flow("enroll", "swag-enrollment", token, "bob", "Bob", "bob@example.com", bob_pw)
        assert ch["component"] == "ak-stage-prompt", ch
        assert "ready" in json.dumps(ch["fields"]), ch
        machine.succeed(f"ldapwhoami {ldap} -D uid=bob,ou=people,{base_dn} -w {bob_pw}")
        assert groups_of("bob") == ["git-users", "members"], groups_of("bob")

    with subtest("a used invitation can't be used again"):
        ch = run_flow("enroll", "swag-enrollment", token, "bob2", "Bob", "bob2@example.com", bob_pw)
        assert ch["component"] == "ak-stage-access-denied", ch

    with subtest("the account syncs into Authentik and can log in"):
        machine.wait_until_succeeds(
            f"curl -sf {auth} '{api}/core/users/?username=bob' | jq -e '.results | length == 1'",
            timeout=120,
        )
        machine.wait_until_succeeds(
            f"curl -sf {auth} '{api}/core/groups/?name=members&include_users=true'"
            " | jq -e '[.results[0].users_obj[].username] | index(\"bob\") != null'",
            timeout=120,
        )
        ch = run_flow("login", "bob", bob_pw)
        assert ch["component"] == "xak-flow-redirect", ch

    with subtest("a login outside the access group waits for approval; superusers pass"):
        ch = run_flow("login", "alice", "alice-initial-pw")
        assert ch["component"] == "ak-stage-access-denied", ch
        assert "waiting for approval" in ch.get("error_message", ""), ch
        ch = run_flow("login", "akadmin", "akadmin-password-1")
        assert ch["component"] == "xak-flow-redirect", ch

    with subtest("an invitation can't grant a group outside grantableGroups"):
        token = invite("eve-invite", ["staff"])
        ch = run_flow("enroll", "swag-enrollment", token, "eve", "Eve", "eve@example.com", "eve-chosen-password-1")
        assert ch["component"] == "ak-stage-access-denied", ch
        machine.fail(f"ldapwhoami {ldap} -D uid=eve,ou=people,{base_dn} -w eve-chosen-password-1")

    with subtest("the enrollment socket is closed to other users"):
        machine.fail("runuser -u nobody -- ${pkgs.python3}/bin/python3 -I ${socketClient} < /dev/null")
        out = machine.succeed(
            "echo '{\"action\": \"create\", \"username\": \"carol\", \"name\": \"Carol\","
            " \"email\": \"carol@example.com\", \"password\": \"carol-password-12\","
            " \"groups\": [\"lldap_admin\"]}'"
            " | systemd-run --wait --pipe --quiet -p DynamicUser=yes"
            " -p SupplementaryGroups=swag-directory-enroll-clients"
            " ${pkgs.python3}/bin/python3 -I ${socketClient}"
        )
        assert json.loads(out)["ok"] is False, out
        machine.fail(f"ldapwhoami {ldap} -D uid=carol,ou=people,{base_dn} -w carol-password-12")

    with subtest("no password appears on a command line or in the journal"):
        machine.fail(f"ps -eo args | grep -F -e {bob_pw} -e admin-password-1 | grep -v grep")
        machine.fail(f"journalctl -b --no-pager | grep -F -e {bob_pw} -e eve-chosen-password-1")
  '';
}
