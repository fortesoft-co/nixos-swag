"""A small lldap client, shared by the directory's units.

Users and groups go through lldap's GraphQL API over HTTP; passwords through
`ldappasswd -y FILE -T FILE`, from copies in the unit's private /tmp, so no
secret is ever on a command line.

cfg keys: httpUrl, ldapUrl, baseDn, adminUsername, ldappasswd, ldapwhoami.
"""

import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


class LldapError(Exception):
    pass


class Lldap:
    def __init__(self, cfg, admin_password):
        self.cfg = cfg
        self.base = cfg["httpUrl"].rstrip("/")
        self.tmp = tempfile.mkdtemp()  # the unit's PrivateTmp, mode 0700
        self.admin_pw_file = self.write_private("admin-password", admin_password)
        self.token = self._login(admin_password)

    def close(self):
        if os.path.exists(self.admin_pw_file):
            os.unlink(self.admin_pw_file)

    def _post(self, path, payload, token=None):
        req = urllib.request.Request(
            self.base + path,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        if token:
            req.add_header("Authorization", "Bearer " + token)
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)

    def _login(self, password):
        # lldap may still be starting; give it a minute.
        for _ in range(60):
            try:
                return self._post(
                    "/auth/simple/login",
                    {"username": self.cfg["adminUsername"], "password": password},
                )["token"]
            except urllib.error.HTTPError:
                raise
            except (urllib.error.URLError, ConnectionError):
                time.sleep(1)
        raise LldapError("lldap did not answer at " + self.base)

    def gql(self, query, variables=None):
        out = self._post(
            "/api/graphql", {"query": query, "variables": variables or {}}, self.token
        )
        if out.get("errors"):
            raise LldapError("lldap GraphQL error: " + json.dumps(out["errors"]))
        return out["data"]

    def write_private(self, name, value):
        path = os.path.join(self.tmp, name)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(value)
        return path

    def user_dn(self, user):
        return "uid=%s,ou=people,%s" % (user, self.cfg["baseDn"])

    def can_bind(self, user, password):
        pw_file = self.write_private("check-password", password)
        try:
            return subprocess.run(
                [
                    self.cfg["ldapwhoami"], "-x", "-H", self.cfg["ldapUrl"],
                    "-D", self.user_dn(user),
                    "-y", pw_file,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode == 0
        finally:
            os.unlink(pw_file)

    def set_password(self, user, password):
        pw_file = self.write_private("new-password", password)
        try:
            subprocess.run(
                [
                    self.cfg["ldappasswd"], "-x", "-H", self.cfg["ldapUrl"],
                    "-D", self.user_dn(self.cfg["adminUsername"]),
                    "-y", self.admin_pw_file,
                    "-T", pw_file,
                    self.user_dn(user),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        finally:
            os.unlink(pw_file)

    def create_user(self, name, email, display_name=None):
        user = {"id": name, "email": email}
        if display_name is not None:
            user["displayName"] = display_name
        self.gql(
            "mutation($u: CreateUserInput!) { createUser(user: $u) { id } }",
            {"u": user},
        )

    def create_group(self, name):
        return self.gql(
            "mutation($n: String!) { createGroup(name: $n) { id } }",
            {"n": name},
        )["createGroup"]["id"]

    def add_to_group(self, user, group_id):
        self.gql(
            "mutation($u: String!, $g: Int!) { addUserToGroup(userId: $u, groupId: $g) { ok } }",
            {"u": user, "g": group_id},
        )

    def delete_user(self, name):
        self.gql(
            "mutation($u: String!) { deleteUser(userId: $u) { ok } }",
            {"u": name},
        )
