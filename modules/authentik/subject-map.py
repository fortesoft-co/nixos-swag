# Prints "SUBJECT <old> <new>" for every Authentik user that came from the
# directory: the hashed ID apps may know them by (user.uid, what OIDC clients
# sent before), and the directory ID clients send from now on. Runs inside
# `manage.py shell` (authentik-subject-map.service), whose wrapper collects
# those lines into services.swag.authentik.directorySource.subjectMap.
#
# The new ID is read from the directory, not from the user's synced "upn"
# attribute, so a user appears here before the sync switches what clients
# send: apps can link the new ID while the old one still works.
import os

from authentik.sources.ldap.models import LDAPSource, UserLDAPSourceConnection, flatten

slug = os.environ["SOURCE_SLUG"]
id_attribute = os.environ["ID_ATTRIBUTE"]

source = LDAPSource.objects.filter(slug=slug).first()
if source is None or not source.enabled or not source.sync_users or not source.bind_password:
    print(f"source {slug}: not set up yet or not syncing users; no subjects to map")
    raise SystemExit(0)

# Users linked by username have no connection until this records one.
exec(open(os.environ["ADOPT_SCRIPT"]).read())

base = source.base_dn
if source.additional_user_dn:
    base = f"{source.additional_user_dn},{base}"
field = source.object_uniqueness_field

directory_ids = {}
for entry in source.connection().extend.standard.paged_search(
    search_base=base,
    search_filter=source.user_object_filter,
    attributes=[field, id_attribute],
    generator=True,
):
    if entry.get("type") != "searchResEntry":
        continue
    attributes = entry.get("attributes", {})
    identifier = flatten(attributes.get(field))
    directory_id = flatten(attributes.get(id_attribute))
    if identifier and directory_id:
        directory_ids[str(identifier)] = str(directory_id)

mapped = 0
for connection in UserLDAPSourceConnection.objects.filter(source=source).select_related("user"):
    new = directory_ids.get(connection.identifier)
    if new and new != connection.user.uid:
        print(f"SUBJECT {connection.user.uid} {new}")
        mapped += 1
print(f"source {slug}: {mapped} users mapped to their directory ID")
