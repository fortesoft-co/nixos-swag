# Deletes a directory user's Authentik side and queues a sync that brings it
# back fresh: same directory account, same directory ID (so apps still know
# them), but no MFA devices, sessions, consents or tokens. For an Authentik
# side that went wrong. exec'd inside `manage.py shell` by
# swag-authentik-reset-user.
import os

from authentik.core.models import User
from authentik.sources.ldap.models import LDAPSource, UserLDAPSourceConnection
from authentik.sources.ldap.tasks import ldap_sync

name = os.environ["RESET_USER"]
source = LDAPSource.objects.filter(slug=os.environ["SOURCE_SLUG"]).first()
if source is None:
    raise SystemExit("the directory source doesn't exist")

user = User.objects.filter(username=name).first()
if user is None:
    raise SystemExit(f"no Authentik user {name!r}")
if not UserLDAPSourceConnection.objects.filter(source=source, user=user).exists():
    raise SystemExit(
        f"{name} doesn't come from the directory; nothing would bring it back. "
        "Delete it in the admin UI instead if that's what you want."
    )

user.delete()
print(f"user {name}: Authentik side deleted")
# Authentik skips a sync while another is running, and that one may have
# read the directory before this user was gone from Authentik; the delayed
# ones run after it.
for delay in (None, 30_000, 120_000):
    ldap_sync.send_with_options(args=(str(source.pk),), delay=delay)
print(
    f"sync queued: {name} comes back from the directory within a few minutes, with the same ID "
    "and password, and sets up MFA again at the next login"
)
