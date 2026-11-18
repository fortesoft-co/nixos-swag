# Removes Authentik users whose directory account is gone. Runs inside
# `manage.py shell` (authentik-directory-prune.service).
#
# Authentik's own option for this (delete_not_found_objects) deletes whatever
# the directory doesn't list, with no limit: a directory answering with no
# users, or with the wrong subtree after a config mistake, would empty
# Authentik, MFA devices included. This does the same comparison, with guards:
#   - the search failing stops the run (ldap3 raises), and a search that finds
#     no user at all is refused: the directory always holds the bind account;
#   - more removals than MAX_PER_RUN in one run are refused, none applied;
#   - superusers are never removed, only reported.
# A refusal fails the unit, so it shows in `systemctl --failed`.
import os

from authentik.sources.ldap.models import LDAPSource, UserLDAPSourceConnection, flatten

slug = os.environ["SOURCE_SLUG"]
limit = int(os.environ["MAX_PER_RUN"])

source = LDAPSource.objects.filter(slug=slug).first()
if source is None or not source.enabled or not source.sync_users:
    print(f"source {slug}: absent, disabled or not syncing users; nothing to do")
    raise SystemExit(0)

base = source.base_dn
if source.additional_user_dn:
    base = f"{source.additional_user_dn},{base}"
field = source.object_uniqueness_field

present = set()
for entry in source.connection().extend.standard.paged_search(
    search_base=base,
    search_filter=source.user_object_filter,
    attributes=[field],
    generator=True,
):
    if entry.get("type") != "searchResEntry":
        continue
    value = flatten(entry.get("attributes", {}).get(field))
    if value:
        present.add(str(value))

if not present:
    raise SystemExit(f"source {slug}: the directory listed no users under {base}; refusing to remove anyone")

gone = [
    c
    for c in UserLDAPSourceConnection.objects.filter(source=source).select_related("user")
    if c.identifier not in present
]
spared = [c for c in gone if c.user.is_superuser]
doomed = [c for c in gone if not c.user.is_superuser]

for c in spared:
    print(f"user {c.user.username}: gone from the directory but a superuser; left in place")

if len(doomed) > limit:
    names = ", ".join(sorted(c.user.username for c in doomed))
    raise SystemExit(
        f"source {slug}: {len(doomed)} users are gone from the directory, more than the "
        f"limit of {limit} per run; removing none. Check the directory, then remove them "
        f"in Authentik by hand or raise directorySource.removeDeletedUsers.maxPerRun: {names}"
    )

for c in doomed:
    name = c.user.username
    c.user.delete()
    print(f"user {name}: gone from the directory; removed")

if not gone:
    print(f"source {slug}: every synced user is still in the directory")
