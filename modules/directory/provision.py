"""Provision declared users and groups into lldap.

Run by swag-directory-provision.service with:
  argv[1]          JSON config (non-secret): see default.nix
  $CREDENTIALS_DIRECTORY/admin-password    lldap admin password
  $CREDENTIALS_DIRECTORY/user-<name>       initial password of <name>

Secrets never appear in argv (see lldap.py).

Users and groups are created when missing; email and display name follow
config; group memberships are only added. Initial passwords are set only
for users this run created; managed passwords (service accounts) whenever
the account can't bind with them.
"""

import json
import os
import sys

from lldap import Lldap

cfg = json.load(open(sys.argv[1]))
creds = os.environ["CREDENTIALS_DIRECTORY"]


def read_secret(name):
    with open(os.path.join(creds, name)) as f:
        return f.read().rstrip("\n")


ld = Lldap(cfg, read_secret("admin-password"))

state = ld.gql(
    "{ users { id email displayName groups { id displayName } }"
    " groups { id displayName } }",
)
groups = {g["displayName"]: g["id"] for g in state["groups"]}
users = {u["id"]: u for u in state["users"]}

for name in cfg["groups"]:
    if name not in groups:
        groups[name] = ld.create_group(name)
        print("group %s: created" % name)

for name, u in cfg["users"].items():
    if name not in users:
        ld.create_user(name, u["email"], u["displayName"])
        print("user %s: created" % name)
        if u["hasInitialPassword"]:
            ld.set_password(name, read_secret("user-" + name))
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
            ld.gql(
                "mutation($u: UpdateUserInput!) { updateUser(user: $u) { ok } }",
                {"u": update},
            )
            print("user %s: updated %s" % (name, ", ".join(k for k in update if k != "id")))
        have = {g["displayName"] for g in cur["groups"]}

    if u["managedPassword"]:
        password = read_secret("user-" + name)
        if not ld.can_bind(name, password):
            ld.set_password(name, password)
            print("user %s: managed password set" % name)

    for g in u["groups"]:
        if g not in have:
            ld.add_to_group(name, groups[g])
            print("user %s: added to %s" % (name, g))

ld.close()
