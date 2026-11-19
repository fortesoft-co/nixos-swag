"""Print every group's members, for apps that act on membership.

Run by swag-directory-groups.service with:
  argv[1]          JSON config (non-secret): see default.nix
  $CREDENTIALS_DIRECTORY/admin-password    lldap admin password

Prints "GROUP <group> <user's directory ID> <username>" per membership;
the unit's wrapper turns them into one file per group under
services.swag.directory.groupMembers. The directory ID is the account's
uuid (LDAP entryUUID), the ID Authentik sends apps for directory users.
Every declared group gets a file, an empty one when it has no members.
"""

import json
import os
import sys

from lldap import Lldap

cfg = json.load(open(sys.argv[1]))
with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "admin-password")) as f:
    ld = Lldap(cfg, f.read().rstrip("\n"))
try:
    groups = ld.gql("{ groups { displayName users { id uuid } } }")["groups"]
finally:
    ld.close()

wanted = set(cfg["groups"])
for group in groups:
    if group["displayName"] not in wanted:
        continue
    wanted.discard(group["displayName"])
    for user in group["users"]:
        print("GROUP %s %s %s" % (group["displayName"], user["uuid"], user["id"]))
for missing in sorted(wanted):
    print("EMPTY %s" % missing)
