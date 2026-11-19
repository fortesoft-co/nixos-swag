# Prints "DIRECTORY_USER yes|no": does Authentik user USER_PK come from the
# directory source SOURCE_SLUG? exec'd inside `manage.py shell` by
# delete-check.py.
import os

from authentik.sources.ldap.models import LDAPSource, UserLDAPSourceConnection

source = LDAPSource.objects.filter(slug=os.environ["SOURCE_SLUG"]).first()
from_directory = (
    source is not None
    and UserLDAPSourceConnection.objects.filter(source=source, user_id=int(os.environ["USER_PK"])).exists()
)
print("DIRECTORY_USER", "yes" if from_directory else "no")
