"""Provision declared users and groups into lldap.

Run by swag-directory-provision.service with:
  argv[1]          JSON config (non-secret): see default.nix
  $CREDENTIALS_DIRECTORY/admin-password    lldap admin password
  $CREDENTIALS_DIRECTORY/user-<name>       initial password of <name>

Secrets never appear in argv: the API is driven over HTTP from this
process, and passwords are set with `ldappasswd -y FILE -T FILE`, from
copies in the unit's private /tmp.

Users and groups are created when missing; email and display name follow
config; group memberships are only added. Initial passwords are set only
for users this run created.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

cfg = json.load(open(sys.argv[1]))
creds = os.environ["CREDENTIALS_DIRECTORY"]
base = cfg["httpUrl"].rstrip("/")


def read_secret(name):
    with open(os.path.join(creds, name)) as f:
        return f.read().rstrip("\n")


def post(path, payload, token=None):
    req = urllib.request.Request(
        base + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def login(password):
    # lldap may still be starting; give it a minute.
    for _ in range(60):
        try:
            return post(
                "/auth/simple/login",
                {"username": cfg["adminUsername"], "password": password},
            )["token"]
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, ConnectionError):
            time.sleep(1)
    raise SystemExit("lldap did not answer at " + base)


def gql(token, query, variables=None):
    out = post("/api/graphql", {"query": query, "variables": variables or {}}, token)
    if out.get("errors"):
        raise SystemExit("lldap GraphQL error: " + json.dumps(out["errors"]))
    return out["data"]


def set_password(admin_pw_file, user, password):
    pw_file = os.path.join(tmp, "new-password")
    fd = os.open(pw_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(password)
    try:
        subprocess.run(
            [
                cfg["ldappasswd"],
                "-x",
                "-H", cfg["ldapUrl"],
                "-D", "uid=%s,ou=people,%s" % (cfg["adminUsername"], cfg["baseDn"]),
                "-y", admin_pw_file,
                "-T", pw_file,
                "uid=%s,ou=people,%s" % (user, cfg["baseDn"]),
            ],
            check=True,
        )
    finally:
        os.unlink(pw_file)


admin_password = read_secret("admin-password")
token = login(admin_password)
tmp = tempfile.mkdtemp()  # the unit's PrivateTmp, mode 0700
admin_pw_file = os.path.join(tmp, "admin-password")
fd = os.open(admin_pw_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(admin_password)

state = gql(
    token,
    "{ users { id email displayName groups { id displayName } }"
    " groups { id displayName } }",
)
groups = {g["displayName"]: g["id"] for g in state["groups"]}
users = {u["id"]: u for u in state["users"]}

for name in cfg["groups"]:
    if name not in groups:
        groups[name] = gql(
            token,
            "mutation($n: String!) { createGroup(name: $n) { id } }",
            {"n": name},
        )["createGroup"]["id"]
        print("group %s: created" % name)

for name, u in cfg["users"].items():
    if name not in users:
        user = {"id": name, "email": u["email"]}
        if u["displayName"] is not None:
            user["displayName"] = u["displayName"]
        gql(
            token,
            "mutation($u: CreateUserInput!) { createUser(user: $u) { id } }",
            {"u": user},
        )
        print("user %s: created" % name)
        if u["hasInitialPassword"]:
            set_password(admin_pw_file, name, read_secret("user-" + name))
            print("user %s: initial password set" % name)
        have = set()
    else:
        cur = users[name]
        update = {"id": name}
        if cur["email"] != u["email"]:
            update["email"] = u["email"]
        if u["displayName"] is not None and cur["displayName"] != u["displayName"]:
            update["displayName"] = u["displayName"]
        if len(update) > 1:
            gql(
                token,
                "mutation($u: UpdateUserInput!) { updateUser(user: $u) { ok } }",
                {"u": update},
            )
            print("user %s: updated %s" % (name, ", ".join(k for k in update if k != "id")))
        have = {g["displayName"] for g in cur["groups"]}

    for g in u["groups"]:
        if g not in have:
            gql(
                token,
                "mutation($u: String!, $g: Int!) { addUserToGroup(userId: $u, groupId: $g) { ok } }",
                {"u": name, "g": groups[g]},
            )
            print("user %s: added to %s" % (name, g))

os.unlink(admin_pw_file)
