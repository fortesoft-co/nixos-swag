# services.swag.accounts against two made-up apps, so no real app is
# needed: "notes" keeps accounts in SQLite and uses the built-in SQL
# adapter (found by directory ID, every op); "media" has a command adapter
# that finds people by username and can only revoke sessions. A third,
# "drafts", is notes' twin left in the default dry run.
#
# Covered: blocking people outside the group and lifting only our own
# blocks; an admin's block stays; local accounts are never touched; linking
# accounts known by an old ID, and refusing a link whose new ID is taken;
# the per-run block limit; a missing members file or subject map changes
# nothing; a failed step doesn't stop held names; dry run changes nothing;
# the SQL adapter on sqlite3 and postgres.
{ pkgs, self }:
let
  schema = pkgs.writeText "notes.sql" ''
    CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT, sso_id TEXT,
                           disabled INTEGER DEFAULT 0, sessions INTEGER DEFAULT 1);
    CREATE TABLE links (account_id INTEGER, sso_id TEXT);
    CREATE TABLE orgs (name TEXT);
    INSERT INTO accounts (id, name, sso_id) VALUES
      (1, 'alice', 'id-alice'), (2, 'bob', 'old-bob'), (3, 'carol', 'id-carol'),
      (4, 'admin', NULL);
    INSERT INTO accounts (id, name, sso_id, disabled) VALUES (5, 'dave', 'id-dave', 1);
    INSERT INTO orgs VALUES ('acme');
  '';

  notesSql = database: {
    identity = "subject";
    inherit database;
    queries = {
      list = ''
        SELECT a.id, a.name, s.sub, a.disabled FROM accounts a LEFT JOIN (
          SELECT id AS aid, sso_id AS sub FROM accounts WHERE sso_id IS NOT NULL
          UNION SELECT account_id, sso_id FROM links) s ON s.aid = a.id
      '';
      names = "SELECT name FROM accounts UNION SELECT name FROM orgs";
      block = "UPDATE accounts SET disabled = 1 WHERE id = :id";
      unblock = "UPDATE accounts SET disabled = 0 WHERE id = :id";
      revoke = "UPDATE accounts SET sessions = 0 WHERE id = :id";
      link = "INSERT INTO links VALUES (:id, :subject)";
    };
  };

  mediaAdapter = pkgs.writers.writePython3 "media-adapter" { flakeIgnore = [ "E501" ]; } ''
    import json
    import os
    import sys

    DB = "/var/lib/media/users.json"
    op = sys.argv[1]
    users = json.load(open(DB))


    def out(o):
        print(json.dumps(o))


    if op == "describe":
        out({"protocol": 1, "identity": "name", "ops": ["revoke"]})
    elif op == "list":
        if os.path.exists("/run/test/media-fail-list"):
            sys.exit("list: the app is down")
        out({"accounts": [{"id": u["id"], "name": u["name"],
                           "subjects": [u["name"]] if u["linked"] else []}
                          for u in users]})
    elif op == "names":
        out({"names": [u["name"] for u in users]})
    elif op == "revoke":
        for u in users:
            if u["id"] == sys.argv[2]:
                u["sessions"] = 0
        json.dump(users, open(DB, "w"))
        out({})
    else:
        sys.exit("unknown op")
  '';

  mediaUsers = pkgs.writeText "users.json" (
    builtins.toJSON [
      {
        id = "m1";
        name = "Alice";
        linked = true;
        sessions = 3;
      }
      {
        id = "m2";
        name = "carol";
        linked = true;
        sessions = 2;
      }
      {
        id = "m3";
        name = "guest";
        linked = false;
        sessions = 1;
      }
    ]
  );
in
pkgs.testers.runNixOSTest {
  name = "swag-accounts";

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [ self.nixosModules.accounts ];

      environment.systemPackages = [
        pkgs.sqlite
        pkgs.python3
      ];
      users.users.notes = {
        isSystemUser = true;
        group = "notes";
      };
      users.groups.notes = { };

      services.postgresql = {
        enable = true;
        ensureDatabases = [ "notes" ];
        ensureUsers = [
          {
            name = "notes";
            ensureDBOwnership = true;
          }
        ];
      };
      systemd.services.test-setup = {
        after = [ "postgresql-setup.service" ];
        requires = [ "postgresql-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [
          pkgs.sqlite
          pkgs.util-linux
          config.services.postgresql.package
        ];
        script = ''
          install -d -m 0755 /run/test /run/held-names
          printf 'id-alice alice\nid-bob bob\nid-dave dave\n' > /run/test/users
          printf 'old-bob id-bob\n' > /run/test/subject-map
          install -d -o notes -g notes /var/lib/notes /var/lib/drafts
          for db in notes drafts; do
            rm -f /var/lib/$db/$db.db
            sqlite3 /var/lib/$db/$db.db < ${schema}
            chown notes:notes /var/lib/$db/$db.db
          done
          runuser -u notes -- psql -q -v ON_ERROR_STOP=1 notes -c 'DROP TABLE IF EXISTS accounts, links, orgs' -f ${schema}
          install -d /var/lib/media
          install -m 0644 ${mediaUsers} /var/lib/media/users.json
        '';
      };

      services.swag.accounts = {
        notes = {
          accessGroup = "users";
          membersFile = "/run/test/users";
          subjectMap = "/run/test/subject-map";
          heldNamesFile = "/run/held-names/notes";
          adapter.sql = notesSql {
            type = "sqlite3";
            path = "/var/lib/notes/notes.db";
          };
          serviceConfig = {
            User = "notes";
            Group = "notes";
            ReadWritePaths = [ "/var/lib/notes" ];
          };
          after = [ "test-setup.service" ];
          maxBlocksPerRun = 2;
          dryRun = false;
        };
        drafts = {
          accessGroup = "users";
          membersFile = "/run/test/users";
          subjectMap = "/run/test/subject-map";
          heldNamesFile = null;
          adapter.sql = notesSql {
            type = "sqlite3";
            path = "/var/lib/drafts/drafts.db";
          };
          serviceConfig = {
            User = "notes";
            Group = "notes";
            ReadWritePaths = [ "/var/lib/drafts" ];
          };
          after = [ "test-setup.service" ];
        };
        # The same app on postgres: peer authentication over the socket, as
        # the unit's own user.
        notespg = {
          accessGroup = "users";
          membersFile = "/run/test/users";
          subjectMap = "/run/test/subject-map";
          heldNamesFile = "/run/held-names/notespg";
          adapter.sql = notesSql {
            type = "postgres";
            user = "notes";
            name = "notes";
          };
          serviceConfig = {
            User = "notes";
            Group = "notes";
          };
          after = [
            "test-setup.service"
            "postgresql-setup.service"
          ];
          dryRun = false;
        };
        media = {
          accessGroup = "users";
          membersFile = "/run/test/users";
          heldNamesFile = "/run/held-names/media";
          adapter.command = "${mediaAdapter}";
          # The adapter keeps its "database" as root's file.
          serviceConfig = {
            User = "root";
            Group = "root";
            ReadWritePaths = [ "/var/lib/media" ];
          };
          after = [ "test-setup.service" ];
          dryRun = false;
        };
      };
    };

  testScript = ''
    import json

    def notes(sql, db="notes"):
        return machine.succeed(f"sqlite3 /var/lib/{db}/{db}.db \"{sql}\"").strip()

    def disabled(name, db="notes"):
        return notes(f"SELECT disabled FROM accounts WHERE name = '{name}'", db) == "1"

    def media():
        return {u["name"]: u for u in json.loads(machine.succeed("cat /var/lib/media/users.json"))}

    def rerun(unit):
        # The first start joins a run a path unit may have begun; the
        # second is a fresh one. Its exit status is the run's.
        machine.execute(f"systemctl start {unit}")
        return machine.execute(f"systemctl start {unit}")[0]

    def journal(unit):
        return machine.succeed(f"journalctl -u {unit} -o cat")

    machine.wait_for_unit("multi-user.target")
    for app in ("notes", "drafts", "notespg", "media"):
        machine.wait_until_succeeds(f"journalctl -u swag-accounts-{app} -o cat | grep -E 'blocked|dry run|failed'", timeout=60)

    with subtest("people outside the group are blocked and their sessions revoked"):
        assert disabled("carol")
        assert notes("SELECT sessions FROM accounts WHERE name = 'carol'") == "0"
        assert not disabled("alice")
        assert notes("SELECT sessions FROM accounts WHERE name = 'alice'") == "1"

    with subtest("local accounts and an admin's block are left alone"):
        assert not disabled("admin")
        assert disabled("dave")
        state = json.loads(machine.succeed("cat /var/lib/swag-accounts/notes/state.json"))
        assert state == {"blocked": ["3"]}, state

    with subtest("an account known by an old ID is linked to the new one, not blocked"):
        assert notes("SELECT sso_id FROM links WHERE account_id = 2") == "id-bob"
        assert not disabled("bob")

    with subtest("held names: every account and organization"):
        assert machine.succeed("cat /run/held-names/notes").split() == ["acme", "admin", "alice", "bob", "carol", "dave"]
        machine.succeed("test $(stat -c %a /run/held-names/notes) = 644")

    with subtest("the same on postgres"):
        def pg(sql):
            return machine.succeed(f"runuser -u notes -- psql -At notes -c \"{sql}\"").strip()
        assert pg("SELECT disabled FROM accounts WHERE name = 'carol'") == "1"
        assert pg("SELECT sessions FROM accounts WHERE name = 'carol'") == "0"
        assert pg("SELECT disabled FROM accounts WHERE name IN ('alice', 'admin', 'bob') ORDER BY name") == "0\n0\n0"
        assert pg("SELECT sso_id FROM links WHERE account_id = 2") == "id-bob"
        assert machine.succeed("cat /run/held-names/notespg").split() == ["acme", "admin", "alice", "bob", "carol", "dave"]

    with subtest("dry run changes nothing"):
        assert not disabled("carol", "drafts")
        assert notes("SELECT count(*) FROM links", "drafts") == "0"
        out = journal("swag-accounts-drafts")
        assert "carol: not in the group; would block (dry run)" in out, out
        assert "bob: would link its new ID (dry run)" in out, out
        machine.fail("test -e /var/lib/swag-accounts/drafts/state.json")

    with subtest("an app that can't block: sessions revoked once, matched by name"):
        m = media()
        assert m["carol"]["sessions"] == 0, m
        assert m["Alice"]["sessions"] == 3, m
        assert m["guest"]["sessions"] == 1, m
        machine.succeed("cat /run/held-names/media | grep -qx guest")
        machine.succeed("python3 -c 'import json; p=\"/var/lib/media/users.json\"; u=json.load(open(p)); u[1][\"sessions\"]=5; json.dump(u, open(p,\"w\"))'")
        assert rerun("swag-accounts-media") == 0
        assert media()["carol"]["sessions"] == 5, "revoked again"

    with subtest("back in the group: our block is lifted, the admin's stays"):
        machine.succeed("printf 'id-alice alice\\nid-bob bob\\nid-carol carol\\nid-dave dave\\n' > /run/test/users")
        machine.wait_until_succeeds("sqlite3 /var/lib/notes/notes.db \"SELECT disabled FROM accounts WHERE name = 'carol'\" | grep -qx 0", timeout=60)
        assert disabled("dave")

    with subtest("a link whose new ID is taken is refused and the run fails"):
        machine.succeed("printf 'id-alice alice\\nid-bob bob\\nid-carol carol\\nid-dave dave\\nold-eve eve\\n' > /run/test/users")
        notes("INSERT INTO accounts (id, name, sso_id) VALUES (6, 'eve', 'old-eve')")
        machine.succeed("printf 'old-bob id-bob\\nold-eve id-alice\\n' > /run/test/subject-map")
        machine.wait_until_succeeds("journalctl -u swag-accounts-notes -o cat | grep -q 'eve: its new ID already belongs to alice'", timeout=60)
        assert notes("SELECT count(*) FROM links WHERE account_id = 6") == "0"
        assert rerun("swag-accounts-notes") != 0
        machine.succeed("printf 'old-bob id-bob\\n' > /run/test/subject-map")

    with subtest("more blocks than the limit: none applied, held names still published"):
        notes("INSERT INTO orgs VALUES ('newco')")
        machine.succeed("printf 'id-dave dave\\n' > /run/test/users")
        machine.wait_until_succeeds("journalctl -u swag-accounts-notes -o cat | grep -q 'more than the limit of 2 per run; blocking none'", timeout=60)
        assert rerun("swag-accounts-notes") != 0
        for name in ("alice", "bob", "carol", "eve"):
            assert not disabled(name), name
        machine.succeed("grep -qx newco /run/held-names/notes")

    with subtest("a configured subject map that isn't there: nobody is checked"):
        machine.succeed("mv /run/test/subject-map /run/test/subject-map.bak")
        assert rerun("swag-accounts-notes") == 0
        assert "subject-map: not there yet; checking nobody until it is" in journal("swag-accounts-notes")
        for name in ("alice", "bob", "carol", "eve"):
            assert not disabled(name), name
        machine.succeed("mv /run/test/subject-map.bak /run/test/subject-map")

    with subtest("no members file: nothing changes"):
        machine.succeed("rm /run/test/users")
        assert rerun("swag-accounts-notes") == 0
        assert "not there yet; nothing to compare with" in journal("swag-accounts-notes")
        for name in ("alice", "bob", "carol", "eve"):
            assert not disabled(name), name

    with subtest("a failed list changes nothing, names are still published"):
        machine.succeed("printf 'id-alice alice\\nid-bob bob\\n' > /run/test/users")
        rerun("swag-accounts-media")
        before = media()
        for u in before.values():
            u["sessions"] = 7
        machine.succeed(f"echo '{json.dumps(list(before.values()))}' > /var/lib/media/users.json")
        machine.succeed("touch /run/test/media-fail-list")
        machine.succeed("python3 -c 'import json; p=\"/var/lib/media/users.json\"; u=json.load(open(p)); u.append({\"id\":\"m4\",\"name\":\"zed\",\"linked\":False,\"sessions\":1}); json.dump(u, open(p,\"w\"))'")
        assert rerun("swag-accounts-media") != 0
        after = media()
        assert all(after[n]["sessions"] == 7 for n in before), after
        machine.succeed("grep -qx zed /run/held-names/media")
  '';
}
