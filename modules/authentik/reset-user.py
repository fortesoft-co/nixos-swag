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
ldap_sync.send(str(source.pk))
print(
    f"sync queued: {name} comes back from the directory within a minute, with the same ID "
    "and password, and sets up MFA again at the next login"
)
