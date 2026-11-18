"""Create one directory account per connection: the directory's enrollment
endpoint.

Run by swag-directory-enroll@.service, one instance per connection to
/run/swag-directory-enroll.sock (Accept=yes; stdin and stdout are the
connection). Only members of the socket's group can connect: the systemd
socket is 0660 and owned by it.

  argv[1]                                  JSON config (non-secret)
  $CREDENTIALS_DIRECTORY/admin-password    lldap admin password

Request, one JSON line:
  {"action": "check" | "create", "username": ..., "name": ..., "email": ...,
   "password": ..., "groups": [...]}
"check" validates and reports whether username and email are free;
"create" does the same, then creates the user, sets the password and adds
the groups. Only groups listed in grantableGroups can be given.

Reply, one JSON line: {"ok": true} or {"ok": false, "error": "<for the user>"}.

Logs go to stderr (the journal) and never contain the password.
"""

import json
import os
import re
import subprocess
import sys

from lldap import Lldap, LldapError

MAX_REQUEST = 16384
USERNAME = re.compile(r"[a-z0-9][a-z0-9._-]{1,31}")
EMAIL = re.compile(r"[^@\s]+@[^@\s]+\.[^@\s]+")

cfg = json.load(open(sys.argv[1]))


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def reply(ok, error=None):
    out = {"ok": ok}
    if error is not None:
        out["error"] = error
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()


def read_request():
    line = sys.stdin.buffer.readline(MAX_REQUEST + 1)
    if len(line) > MAX_REQUEST:
        raise ValueError("request too large")
    req = json.loads(line)
    if not isinstance(req, dict):
        raise ValueError("request is not an object")
    return req


def validate(req):
    """Return the cleaned request, or raise ValueError with a user-facing message."""
    action = req.get("action")
    if action not in ("check", "create"):
        raise ValueError("unknown action")
    username = req.get("username")
    name = req.get("name")
    email = req.get("email")
    password = req.get("password")
    groups = req.get("groups") or []
    if not isinstance(username, str) or not USERNAME.fullmatch(username):
        raise ValueError(
            "Usernames are 2 to 32 characters: lowercase letters, digits, '.', '_' and '-', "
            "starting with a letter or digit."
        )
    if not isinstance(email, str) or len(email) > 254 or not EMAIL.fullmatch(email):
        raise ValueError("Enter a valid email address.")
    if not isinstance(name, str) or not 0 < len(name.strip()) <= 100 or not name.isprintable():
        raise ValueError("Enter your name (up to 100 characters).")
    if not isinstance(password, str) or len(password) > 256:
        raise ValueError("Enter a password.")
    if len(password) < cfg["minPasswordLength"]:
        raise ValueError(
            "Passwords need at least %d characters." % cfg["minPasswordLength"]
        )
    if not isinstance(groups, list) or not all(isinstance(g, str) for g in groups):
        raise ValueError("invalid groups")
    not_grantable = sorted(set(groups) - set(cfg["grantableGroups"]))
    if not_grantable:
        # Only reachable through a hand-made invitation; say which.
        log("refused: groups not grantable: %s" % ", ".join(not_grantable))
        raise ValueError(
            "This invitation grants groups that can't be given at sign-up: %s."
            % ", ".join(not_grantable)
        )
    return action, username, name.strip(), email, password, sorted(set(groups))


def main():
    try:
        action, username, name, email, password, groups = validate(read_request())
    except (ValueError, UnicodeDecodeError) as e:
        reply(False, str(e))
        return

    creds = os.environ["CREDENTIALS_DIRECTORY"]
    with open(os.path.join(creds, "admin-password")) as f:
        ld = Lldap(cfg, f.read().rstrip("\n"))
    try:
        state = ld.gql("{ users { id email } groups { id displayName } }")
        if any(u["id"].lower() == username for u in state["users"]):
            reply(False, "That username is taken.")
            return
        if any(u["email"].lower() == email.lower() for u in state["users"]):
            reply(False, "That email address already has an account.")
            return
        group_ids = {g["displayName"]: g["id"] for g in state["groups"]}
        missing = [g for g in groups if g not in group_ids]
        if missing:
            log("refused: groups missing from the directory: %s" % ", ".join(missing))
            reply(False, "This invitation refers to groups that don't exist.")
            return
        if action == "check":
            reply(True)
            return

        ld.create_user(username, email, name)
        try:
            ld.set_password(username, password)
            for g in groups:
                ld.add_to_group(username, group_ids[g])
        except Exception:
            # Don't leave a half-made account behind: a retry would find
            # the username taken.
            ld.delete_user(username)
            raise
        log(
            "created %s (%s)"
            % (username, ", ".join(groups) if groups else "no groups: awaiting approval")
        )
        reply(True)
    except (LldapError, OSError, subprocess.SubprocessError) as e:
        log("failed for %s: %s" % (username, e))
        reply(False, "The account could not be created. Please try again later.")
    finally:
        ld.close()


main()
