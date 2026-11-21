"""The built-in adapter for apps that keep their accounts in SQL.

  sql-adapter.py <config.json> <op> [args...]

The config (non-secret, from services.swag.accounts.<app>.sql) names the
database (sqlite3 file, or postgres through psql over a local socket) and
the SQL for each op. Ops without SQL aren't offered in describe.

  list     rows of (id, name, subject, blocked), one per subject; an
           account without subjects has one row with subject NULL
  names    rows of (name)
  block, unblock, revoke    statements run with :id
  link                      statements run with :id and :subject

Statements of one op run in one transaction. Parameters are bound by
sqlite3; for psql they're inlined as quoted literals and the SQL goes on
stdin, never on a command line. Write :id and :subject only where a value
belongs, not inside string literals.
"""

import json
import re
import subprocess
import sys

PARAM = re.compile(r"(?<![:\w]):([A-Za-z_]\w*)")


class Sqlite:
    def __init__(self, c):
        import sqlite3

        self.db = sqlite3.connect(c["path"], timeout=30)

    def rows(self, sql):
        return [tuple(r) for r in self.db.execute(sql).fetchall()]

    def run(self, statements, params):
        with self.db:
            for sql in statements:
                names = set(PARAM.findall(sql))
                self.db.execute(sql, {k: v for k, v in params.items() if k in names})


class Postgres:
    def __init__(self, c):
        self.base = [c["psql"], "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
                     "-h", c["host"], "-p", str(c["port"]), "-U", c["user"], c["name"]]

    @staticmethod
    def lit(v):
        return "'" + str(v).replace("'", "''") + "'"

    def fill(self, sql, params):
        return PARAM.sub(lambda m: self.lit(params[m.group(1)]), sql)

    def psql(self, sql):
        return subprocess.run(self.base, input=sql, text=True, stdout=subprocess.PIPE,
                              check=True).stdout

    def rows(self, sql):
        # One JSON array of row objects (columns in order), so values with
        # newlines survive psql's output.
        out = self.psql("SELECT coalesce(json_agg(t), '[]'::json) FROM (%s) t;" % sql).strip()
        return [tuple(r.values()) for r in json.loads(out)]

    def run(self, statements, params):
        body = "".join(self.fill(sql, params) + ";\n" for sql in statements)
        self.psql("BEGIN;\n" + body + "COMMIT;\n")


cfg = json.load(open(sys.argv[1]))
op, args = sys.argv[2], sys.argv[3:]
q = cfg["queries"]
offered = [o for o in ("block", "unblock", "revoke", "link") if q.get(o)]


def db():
    c = cfg["database"]
    return Sqlite(c) if c["type"] == "sqlite3" else Postgres(c)


def out(obj):
    json.dump(obj, sys.stdout)
    sys.stdout.write("\n")


if op == "describe":
    out({"protocol": 1, "identity": cfg["identity"], "ops": offered})
elif op == "list":
    accounts = {}
    for aid, name, subject, blocked in db().rows(q["list"]):
        a = accounts.setdefault(str(aid), {"id": str(aid), "name": str(name),
                                           "subjects": [], "blocked": False})
        if subject is not None and str(subject) not in a["subjects"]:
            a["subjects"].append(str(subject))
        a["blocked"] = a["blocked"] or bool(blocked)
    out({"accounts": list(accounts.values())})
elif op == "names":
    out({"names": [str(r[0]) for r in db().rows(q["names"]) if r[0] is not None]})
elif op in offered:
    want = 2 if op == "link" else 1
    if len(args) != want:
        sys.exit("%s takes %d argument(s)" % (op, want))
    params = {"id": args[0]}
    if op == "link":
        params["subject"] = args[1]
    db().run(q[op], params)
    out({})
else:
    sys.exit("unknown op: %s" % op)
