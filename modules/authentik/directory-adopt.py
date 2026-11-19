# Records which directory account each username-linked user came from.
# exec'd inside `manage.py shell` with `source` (the LDAPSource) defined.
#
# With user_matching_mode username_link, the sync attaches a directory
# account to an Authentik user that already existed by username, but never
# saves the source connection for it (only users the sync creates get one).
# Everything that asks "which users came from the directory" goes by those
# connections (the subject map, the removal of deleted users), so such a
# user would be invisible to them. This saves the connection the sync would
# have: same identifier (swag's source uses uid for both the identifier and
# the username), same user, matched by username exactly as the sync does.
from authentik.core.models import User
from authentik.sources.ldap.models import UserLDAPSourceConnection, flatten

if source.sync_users and source.user_matching_mode == "username_link":
    adopt_base = source.base_dn
    if source.additional_user_dn:
        adopt_base = f"{source.additional_user_dn},{adopt_base}"
    adopt_field = source.object_uniqueness_field

    connected_users = set(
        UserLDAPSourceConnection.objects.filter(source=source).values_list("user_id", flat=True)
    )
    connected_ids = set(
        UserLDAPSourceConnection.objects.filter(source=source).values_list("identifier", flat=True)
    )
    for adopt_entry in source.connection().extend.standard.paged_search(
        search_base=adopt_base,
        search_filter=source.user_object_filter,
        attributes=[adopt_field],
        generator=True,
    ):
        if adopt_entry.get("type") != "searchResEntry":
            continue
        adopt_id = flatten(adopt_entry.get("attributes", {}).get(adopt_field))
        if not adopt_id or str(adopt_id) in connected_ids:
            continue
        adopt_user = User.objects.filter(username=str(adopt_id)).first()
        if adopt_user is None or adopt_user.pk in connected_users:
            continue
        UserLDAPSourceConnection.objects.create(source=source, user=adopt_user, identifier=str(adopt_id))
        connected_users.add(adopt_user.pk)
        print(f"user {adopt_user.username}: linked by username; recorded as from the directory")
