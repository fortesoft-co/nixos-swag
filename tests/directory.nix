# services.swag.directory: provisioning, initial-only passwords, and secrets
# that only the consuming unit can read.
{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "swag-directory";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.directory ];

      environment.systemPackages = [ pkgs.openldap ];
      users.users.mallory.isNormalUser = true;

      # Root-only secret files, as agenix or sops-nix would leave them
      # (trailing newline included, as an editor writes it).
      systemd.services.test-secrets = {
        wantedBy = [ "multi-user.target" ];
        before = [
          "lldap.service"
          "swag-directory-provision.service"
        ];
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0700 /run/test-secrets
          umask 077
          echo 'admin-password-1' > /run/test-secrets/admin
          echo 'alice-initial-pw' > /run/test-secrets/alice
        '';
      };
      systemd.services.lldap.requires = [ "test-secrets.service" ];

      services.swag.directory = {
        enable = true;
        baseDn = "dc=example,dc=com";
        adminPasswordFile = "/run/test-secrets/admin";
        groups.family = { };
        users.alice = {
          email = "alice@example.com";
          displayName = "Alice";
          groups = [ "family" ];
          initialPasswordFile = "/run/test-secrets/alice";
        };
        users.bob.email = "bob@example.com";
      };
    };

  testScript = ''
    ldap = "-x -H ldap://127.0.0.1:3890"
    alice = "uid=alice,ou=people,dc=example,dc=com"
    admin = "-D uid=admin,ou=people,dc=example,dc=com -w admin-password-1"

    machine.wait_for_unit("swag-directory-provision.service")

    with subtest("users, groups and the initial password are provisioned"):
        machine.succeed(f"ldapwhoami {ldap} -D {alice} -w alice-initial-pw")
        machine.succeed(
            f"ldapsearch {ldap} {admin} -b ou=groups,dc=example,dc=com '(cn=family)' member"
            f" | grep -F 'member: {alice}'"
        )
        machine.succeed(
            f"ldapsearch {ldap} {admin} -b ou=people,dc=example,dc=com '(uid=bob)' mail"
            " | grep -F 'mail: bob@example.com'"
        )

    with subtest("secrets are readable only by the unit that needs them"):
        machine.fail("su mallory -c 'cat /run/test-secrets/alice'")
        machine.fail("su mallory -c 'cat /run/credentials/lldap.service/admin-password'")
        machine.fail("su mallory -c 'ls /run/credentials/swag-directory-provision.service'")
        machine.fail("ps -eo args | grep -F -e admin-password-1 -e alice-initial-pw | grep -v grep")

    with subtest("a password the user changed survives re-provisioning"):
        machine.succeed(f"ldappasswd {ldap} -D {alice} -w alice-initial-pw -s alice-chosen-pw {alice}")
        machine.succeed("systemctl restart swag-directory-provision.service")
        machine.succeed(f"ldapwhoami {ldap} -D {alice} -w alice-chosen-pw")
        machine.fail(f"ldapwhoami {ldap} -D {alice} -w alice-initial-pw")

    with subtest("provisioning is idempotent"):
        out = machine.succeed("systemctl restart swag-directory-provision.service && journalctl -u swag-directory-provision -n 20 -o cat")
        assert "created" not in out.split("Starting")[-1], out

    with subtest("group members are published by directory ID, one file per group"):
        machine.succeed("systemctl start swag-directory-groups.service")
        uuid = machine.succeed(
            f"ldapsearch {ldap} {admin} -b ou=people,dc=example,dc=com -LLL '(uid=alice)' entryUUID"
            " | sed -n 's/^entryUUID: //Ip'"
        ).strip()
        assert uuid, "no entryUUID for alice"
        published = machine.succeed("cat /run/swag-directory/groups/family").strip()
        assert published == f"{uuid} alice", f"published {published!r}, LDAP says {uuid!r}"
        assert machine.succeed("stat -c %a /run/swag-directory/groups/family").strip() == "644"
        assert machine.succeed("ls -A /run/swag-directory/groups").split() == ["family"]
        machine.fail("su mallory -c 'touch /run/swag-directory/groups/family'")
  '';
}
