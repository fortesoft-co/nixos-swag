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
      };
    };

  testScript = ''
    import json

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

    with subtest("a password set in Authentik is written back to the directory"):
        machine.succeed(
            f"curl -sf {auth} -X POST -H 'Content-Type: application/json'"
            f" -d '{{\"password\": \"alice-changed-in-ak\"}}' '{api}/core/users/{alice['pk']}/set_password/'"
        )
        machine.wait_until_succeeds(f"ldapwhoami {ldap} -D {alice_dn} -w alice-changed-in-ak", timeout=60)
        machine.fail(f"ldapwhoami {ldap} -D {alice_dn} -w alice-initial-pw")

    with subtest("no secret appears on a command line"):
        machine.fail(
            "ps -eo args | grep -F -e bind-password-xyz -e alice-initial-pw -e admin-password-1 | grep -v grep"
        )
  '';
}
