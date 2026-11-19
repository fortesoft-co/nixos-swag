"""nginx auth_request target: may this request to /api/v3/core/users/<pk>/ go
through? One instance per connection (swag-authentik-delete-check@), the
connection as stdin/stdout, running as the Authentik server does.

  argv[1]  manage.py   argv[2]  delete-check-query.py   argv[3]  source slug

Anything but DELETE passes at once. A DELETE of a user that came from the
directory is refused (403): the directory decides who exists, and the sync
would bring the user back anyway, without their MFA devices. Users that
don't come from the directory (akadmin, service accounts) can be deleted.
When the answer can't be had, the deletion is refused too (500).
"""

import os
import re
import subprocess
import sys

manage_py, query, slug = sys.argv[1:4]


def reply(status, reason):
    sys.stdout.write(
        f"HTTP/1.1 {status} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    )
    sys.stdout.flush()
    raise SystemExit(0)


sys.stdin.readline()  # request line: nginx's subrequest, not the client's
headers = {}
for line in sys.stdin:
    line = line.rstrip("\r\n")
    if not line:
        break
    key, _, value = line.partition(":")
    headers[key.strip().lower()] = value.strip()

if headers.get("x-original-method") != "DELETE":
    reply(204, "No Content")

match = re.fullmatch(r"/api/v3/core/users/([0-9]{1,18})/(\?.*)?", headers.get("x-original-uri", ""))
if not match:
    reply(403, "Forbidden")
pk = match.group(1)

try:
    result = subprocess.run(
        [manage_py, "shell", "-c", f'exec(open("{query}").read())'],
        env={**os.environ, "USER_PK": pk, "SOURCE_SLUG": slug},
        capture_output=True,
        text=True,
        timeout=50,
    )
    answer = next(
        (l.split()[1] for l in result.stdout.splitlines() if l.startswith("DIRECTORY_USER ")), None
    )
except (OSError, subprocess.SubprocessError) as e:
    print(f"user {pk}: check failed ({e}); deletion refused", file=sys.stderr)
    reply(500, "Internal Server Error")

if answer == "yes":
    print(f"user {pk}: comes from the directory; deletion refused", file=sys.stderr)
    reply(403, "Forbidden")
if answer == "no":
    reply(204, "No Content")
print(f"user {pk}: no answer from Authentik; deletion refused: {result.stderr[-500:]}", file=sys.stderr)
reply(500, "Internal Server Error")
