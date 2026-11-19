# services.swag.authentik.directorySource against services.swag.directory:
# users and groups sync from lldap into Authentik, and a password set in
# Authentik is written back to lldap.
{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "swag-authentik-directory";

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
          echo 'app-client-secret-0123456789' > /run/test-secrets/app-client
        '';
      };
      systemd.services.lldap.requires = [ "test-secrets.service" ];
      systemd.services.authentik-secrets.requires = [ "test-secrets.service" ];

      services.swag.directory = {
        enable = true;
        baseDn = "dc=example,dc=com";
        adminPasswordFile = "/run/test-secrets/lldap-admin";
        groups.family = { };
        users.alice = {
          email = "alice@example.com";
          displayName = "Alice";
          groups = [ "family" ];
          initialPasswordFile = "/run/test-secrets/alice";
        };
        # Removed from the directory during the test.
        users.bob.email = "bob@example.com";
        users.carol.email = "carol@example.com";
        users.dave.email = "dave@example.com";
        users.erin.email = "erin@example.com";
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
          removeDeletedUsers.maxPerRun = 1;
        };
        url = "http://127.0.0.1:9000";
        # An OIDC client, to check the subject mode it gets.
        oidcClients.app = {
          name = "App";
          clientSecretFile = "/run/test-secrets/app-client";
          redirectUris = [ "http://127.0.0.1:8080/callback" ];
        };
      };
    };

  testScript = ''
    import json
    import shlex

    api = "http://127.0.0.1:9000/api/v3"
    auth = "-H 'Authorization: Bearer test-api-token-0123456789'"
    ldap = "-x -H ldap://127.0.0.1:3890"
    alice_dn = "uid=alice,ou=people,dc=example,dc=com"

    def get(path):
        return json.loads(machine.succeed(f"curl -sf {auth} '{api}{path}'"))

    machine.wait_for_unit("swag-directory-provision.service")
    machine.wait_for_unit("authentik.service")
    machine.wait_for_open_port(9000, timeout=600)
    machine.wait_for_unit("authentik-directory-source-setup.service", timeout=600)

    with subtest("the bind account exists in the directory with its managed password"):
        machine.succeed(f"ldapwhoami {ldap} -D uid=authentik,ou=people,dc=example,dc=com -w bind-password-xyz")

    with subtest("directory users and groups sync into Authentik"):
        machine.wait_until_succeeds(
            f"curl -sf {auth} '{api}/core/users/?username=alice' | jq -e '.results | length == 1'",
            timeout=600,
        )
        alice = get("/core/users/?username=alice")["results"][0]
        assert alice["email"] == "alice@example.com", alice
        machine.wait_until_succeeds(
            f"curl -sf {auth} '{api}/core/groups/?name=family&include_users=true'"
            " | jq -e '[.results[0].users_obj[].username] | index(\"alice\") != null'",
            timeout=300,
        )

    def lldap_gql(query, check):
        login = json.dumps({"username": "admin", "password": "admin-password-1"})
        token = json.loads(machine.succeed(
            f"curl -sf -H 'Content-Type: application/json' -d {shlex.quote(login)}"
            " http://127.0.0.1:17170/auth/simple/login"
        ))["token"]
        body = json.dumps({"query": query})
        machine.succeed(
            f"curl -sf -H 'Authorization: Bearer {token}' -H 'Content-Type: application/json'"
            f" -d {shlex.quote(body)} http://127.0.0.1:17170/api/graphql | jq -e '{check}'"
        )

    def entry_uuid(user):
        out = machine.succeed(
            f"ldapsearch {ldap} -D uid=admin,ou=people,dc=example,dc=com -w admin-password-1"
            f" -b ou=people,dc=example,dc=com -LLL '(uid={user})' entryUUID"
        )
        return next(l.split(":", 1)[1].strip() for l in out.splitlines() if l.lower().startswith("entryuuid:"))

    def resync():
        machine.succeed("systemctl restart authentik-directory-source-setup.service")

    with subtest("a directory user carries the directory's ID, and apps are sent it"):
        uuid = entry_uuid("alice")
        machine.wait_until_succeeds(
            f"curl -sf {auth} '{api}/core/users/?username=alice' | jq -e '.results[0].attributes.upn == \"{uuid}\"'",
            timeout=120,
        )
        provider = get("/providers/oauth2/?name=app")["results"][0]
        assert provider["sub_mode"] == "user_upn", provider
        akadmin = get("/core/users/?username=akadmin")["results"][0]
        assert "upn" not in akadmin["attributes"], akadmin

    with subtest("the subject map pairs each directory user's old ID with the new one"):
        machine.succeed("systemctl start authentik-subject-map.service")
        alice = get("/core/users/?username=alice")["results"][0]
        lines = machine.succeed("cat /run/swag-authentik/subject-map").splitlines()
        assert f"{alice['uid']} {uuid}" in lines, lines
        assert not any(akadmin["uid"] in l for l in lines), lines
        assert machine.succeed("stat -c %a /run/swag-authentik/subject-map").strip() == "644"

    with subtest("a user that existed before the directory is recognized as from it"):
        # Authentik first, the directory account later: the sync links them by
        # username without recording a connection; setup records it.
        pk = json.loads(machine.succeed(
            f"curl -sf {auth} -X POST -H 'Content-Type: application/json'"
            " -d '{\"username\": \"frank\", \"name\": \"Frank\"}'"
            f" '{api}/core/users/'"
        ))["pk"]
        lldap_gql(
            'mutation { createUser(user: {id: "frank", email: "frank@example.com"}) { id } }',
            '.data.createUser.id == "frank"',
        )
        resync()
        machine.succeed("systemctl start authentik-subject-map.service")
        frank = get("/core/users/?username=frank")["results"][0]
        assert frank["pk"] == pk, "frank was re-created instead of linked"
        lines = machine.succeed("cat /run/swag-authentik/subject-map").splitlines()
        assert f"{frank['uid']} {entry_uuid('frank')}" in lines, lines
        # Whichever runs first records it: the subject map, or the setup.
        out = machine.succeed("journalctl -u authentik-subject-map -u authentik-directory-source-setup -o cat")
        assert "user frank: linked by username; recorded as from the directory" in out, out

    with subtest("deleted in Authentik and re-created by the sync, the ID stays"):
        machine.succeed(f"curl -sf {auth} -X DELETE '{api}/core/users/{alice['pk']}/'")
        resync()
        machine.wait_until_succeeds(
            f"curl -sf {auth} '{api}/core/users/?username=alice' | jq -e '.results[0].attributes.upn == \"{uuid}\"'",
            timeout=120,
        )
        recreated = get("/core/users/?username=alice")["results"][0]
        assert recreated["pk"] != alice["pk"], "alice was not re-created"
        alice = recreated

    with subtest("a password set in Authentik is written back to the directory"):
        machine.succeed(
            f"curl -sf {auth} -X POST -H 'Content-Type: application/json'"
            f" -d '{{\"password\": \"alice-changed-in-ak\"}}' '{api}/core/users/{alice['pk']}/set_password/'"
        )
        machine.wait_until_succeeds(f"ldapwhoami {ldap} -D {alice_dn} -w alice-changed-in-ak", timeout=60)
        machine.fail(f"ldapwhoami {ldap} -D {alice_dn} -w alice-initial-pw")

    def lldap_delete(user):
        lldap_gql(f'mutation {{ deleteUser(userId: "{user}") {{ ok }} }}', ".data.deleteUser.ok")

    def journal(expect):
        cmd = "journalctl -u authentik-directory-prune.service -o cat"
        machine.wait_until_succeeds(f"{cmd} | grep -qF {shlex.quote(expect)}", timeout=30)
        return machine.succeed(cmd)

    def in_authentik(user):
        return len(get(f"/core/users/?username={user}")["results"]) == 1

    with subtest("a user gone from the directory is removed from Authentik, a superuser is not"):
        for u in ["bob", "carol", "dave", "erin"]:
            machine.wait_until_succeeds(
                f"curl -sf {auth} '{api}/core/users/?username={u}' | jq -e '.results | length == 1'",
                timeout=300,
            )
        admins = get("/core/groups/?name=authentik%20Admins")["results"][0]["pk"]
        erin = get("/core/users/?username=erin")["results"][0]["pk"]
        machine.succeed(
            f"curl -sf {auth} -X POST -H 'Content-Type: application/json'"
            f" -d '{{\"pk\": {erin}}}' '{api}/core/groups/{admins}/add_user/'"
        )
        lldap_delete("bob")
        lldap_delete("erin")
        machine.succeed("systemctl start authentik-directory-prune.service")
        out = journal("user bob: gone from the directory; removed")
        assert "user erin: gone from the directory but a superuser" in out, out
        assert not in_authentik("bob"), out
        assert in_authentik("erin"), out
        for u in ["alice", "carol", "dave", "akadmin"]:
            assert in_authentik(u), f"{u} removed: {out}"

    with subtest("more removals than maxPerRun: none applied, the unit fails"):
        lldap_delete("carol")
        lldap_delete("dave")
        machine.fail("systemctl start authentik-directory-prune.service")
        out = journal("more than the limit of 1 per run; removing none")
        assert in_authentik("carol") and in_authentik("dave"), out

    with subtest("no secret appears on a command line"):
        machine.fail(
            "ps -eo args | grep -F -e bind-password-xyz -e alice-initial-pw -e admin-password-1 | grep -v grep"
        )
  '';
}
