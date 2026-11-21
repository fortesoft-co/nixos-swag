"""Keep one app's accounts in line with the directory.

Run by swag-accounts-<app>.service, as the app's unit user:
  argv[1]   JSON config (non-secret): see default.nix

The app is reached only through its adapter, a command answering
`<adapter> <op> [args...]` with one JSON object on stdout (logs on stderr,
exit 0 = done, including "already so"). Ops: describe, list, names, and
optionally block, unblock, revoke, link. This script holds the policy; the
adapter only does what it's told.

A run, in order:
  1. link: an account known by an old ID (subject map) gets its new one
     too, unless another account already has it (conflict: skipped,
     reported, the run fails) or several accounts share the old one.
  2. block / lift: an account none of whose subjects is in the members file
     is blocked (and its sessions revoked); one blocked by this script whose
     owner is back is unblocked. Blocks an admin set are left alone, and
     accounts without subjects (local, service, bot) are never touched.
  3. names: every name the app holds is written for enrollment to refuse.

Guards: no members file, or a subject map that is configured but not
there yet, means nothing to compare with, so step 1 and 2 change nothing.
More blocks than maxBlocksPerRun applies none of them. A failed step
doesn't stop the later ones; the run exits non-zero at the end. dryRun
logs what steps 1 and 2 would do and changes nothing in the app (names are
still published: they only make sign-up refuse more).
"""

import json
import os
import subprocess
import sys

PROTOCOL = 1
OPTIONAL_OPS = {"block", "unblock", "revoke", "link"}

sys.stdout.reconfigure(line_buffering=True)

cfg = json.load(open(sys.argv[1]))
app = cfg["name"]
dry = cfg["dryRun"]
failures = []


def log(msg):
    print("%s: %s" % (app, msg))


class AdapterError(Exception):
    pass


def call(op, *args):
    argv = cfg["adapter"] + [op] + list(args)
    r = subprocess.run(argv, stdout=subprocess.PIPE, text=True)
    if r.returncode != 0:
        raise AdapterError("adapter %s failed (exit %d)" % (op, r.returncode))
    try:
        out = json.loads(r.stdout)
    except ValueError:
        raise AdapterError("adapter %s: output is not JSON" % op)
    if not isinstance(out, dict):
        raise AdapterError("adapter %s: output is not a JSON object" % op)
    return out


def read_lines(path):
    with open(path) as f:
        return [line.split() for line in f if line.strip()]


def describe():
    d = call("describe")
    if d.get("protocol") != PROTOCOL:
        raise AdapterError("adapter speaks protocol %r, this core speaks %d"
                           % (d.get("protocol"), PROTOCOL))
    if d.get("identity") not in ("subject", "name"):
        raise AdapterError("adapter identity %r: expected subject or name" % d.get("identity"))
    ops = set(d.get("ops", []))
    unknown = ops - OPTIONAL_OPS
    if unknown:
        raise AdapterError("adapter offers unknown ops: %s" % ", ".join(sorted(unknown)))
    return d["identity"], ops


def list_accounts():
    accounts = call("list").get("accounts")
    if not isinstance(accounts, list):
        raise AdapterError("adapter list: no accounts array")
    out = {}
    for a in accounts:
        try:
            aid, name = str(a["id"]), str(a["name"])
            subjects = {str(s) for s in a.get("subjects") or []}
            blocked = bool(a.get("blocked", False))
        except (KeyError, TypeError):
            raise AdapterError("adapter list: malformed account %r" % (a,))
        if aid in out:
            raise AdapterError("adapter list: account %s listed twice" % aid)
        out[aid] = {"name": name, "subjects": subjects, "blocked": blocked}
    return out


def load_state():
    try:
        with open(cfg["stateFile"]) as f:
            return set(json.load(f).get("blocked", []))
    except FileNotFoundError:
        return set()


def save_state(ours):
    tmp = cfg["stateFile"] + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"blocked": sorted(ours)}, f)
    os.replace(tmp, cfg["stateFile"])


def link(accounts, renamed):
    """Give accounts known by an old ID their new one. Returns conflicts."""
    owners = {}
    for aid, a in accounts.items():
        for s in a["subjects"]:
            owners.setdefault(s, set()).add(aid)
    conflicts = 0
    for old, new in sorted(renamed.items()):
        olds = owners.get(old, set())
        if len(olds) > 1:
            log("old ID shared by %s; not linked"
                % ", ".join(sorted(accounts[a]["name"] for a in olds)))
            continue
        if not olds:
            continue
        aid = next(iter(olds))
        others = owners.get(new, set()) - {aid}
        if others:
            log("%s: its new ID already belongs to %s; left alone (if %s should have it, "
                "remove the other account's claim first)"
                % (accounts[aid]["name"], ", ".join(sorted(accounts[o]["name"] for o in others)),
                   accounts[aid]["name"]))
            conflicts += 1
            continue
        if new in accounts[aid]["subjects"]:
            continue
        if dry:
            log("%s: would link its new ID (dry run)" % accounts[aid]["name"])
            continue
        try:
            call("link", aid, new)
        except AdapterError as e:
            failures.append("link %s: %s" % (accounts[aid]["name"], e))
            continue
        accounts[aid]["subjects"].add(new)
        owners.setdefault(new, set()).add(aid)
        log("%s: linked to its new ID" % accounts[aid]["name"])
    return conflicts


def lifecycle():
    try:
        identity, ops = describe()
    except AdapterError as e:
        failures.append(str(e))
        return

    if cfg["membersFile"] is None:
        return
    try:
        members_rows = read_lines(cfg["membersFile"])
    except FileNotFoundError:
        log("%s: not there yet; nothing to compare with" % cfg["membersFile"])
        return
    renamed = {}
    if cfg["subjectMap"] is not None and identity == "subject":
        try:
            renamed = {r[0]: r[1] for r in read_lines(cfg["subjectMap"]) if len(r) == 2}
        except FileNotFoundError:
            log("%s: not there yet; checking nobody until it is" % cfg["subjectMap"])
            return

    if identity == "subject":
        members = {r[0] for r in members_rows}
    else:
        members = {r[1].lower() for r in members_rows if len(r) >= 2}

    try:
        accounts = list_accounts()
    except AdapterError as e:
        failures.append(str(e))
        return

    if renamed and "link" in ops:
        conflicts = link(accounts, renamed)
        if conflicts:
            failures.append("%d link conflict(s)" % conflicts)

    ours = load_state()
    can_block = "block" in ops
    if not can_block:
        log("the app can't block accounts; relying on the identity provider"
            + (" and revoking sessions" if "revoke" in ops else ""))

    to_block, to_lift = [], []
    for aid, a in sorted(accounts.items()):
        if not a["subjects"]:
            continue
        if identity == "subject":
            known = a["subjects"] | {renamed[s] for s in a["subjects"] if s in renamed}
        else:
            known = {s.lower() for s in a["subjects"]}
        inside = bool(known & members)
        # Without a block op, "blocked" means "handled by us already".
        blocked = a["blocked"] if can_block else aid in ours
        if not inside and not blocked:
            to_block.append(aid)
        elif inside and blocked and aid in ours:
            to_lift.append(aid)
        elif inside and not blocked:
            # Back in the group, or lifted by hand: no longer ours to lift.
            ours.discard(aid)

    names = lambda ids: ", ".join(accounts[a]["name"] for a in ids)

    if len(to_block) > cfg["maxBlocksPerRun"]:
        failures.append(
            "%d accounts left the group, more than the limit of %d per run; blocking none: %s"
            % (len(to_block), cfg["maxBlocksPerRun"], names(to_block)))
        log(failures[-1])
        to_block = []

    if dry:
        for aid in to_block:
            log("%s: not in the group; would block (dry run)" % accounts[aid]["name"])
        for aid in to_lift:
            log("%s: back in the group; would unblock (dry run)" % accounts[aid]["name"])
        log("dry run: nothing changed")
        return

    blocked_n = lifted_n = 0
    for aid in to_block:
        n = accounts[aid]["name"]
        try:
            if can_block:
                call("block", aid)
            if "revoke" in ops:
                call("revoke", aid)
        except AdapterError as e:
            failures.append("block %s: %s" % (n, e))
            continue
        ours.add(aid)
        blocked_n += 1
        log("%s: not in the group; %s" % (n, "sign-in blocked" if can_block
                                          else "sessions revoked" if "revoke" in ops
                                          else "can't block it here"))
    for aid in to_lift:
        n = accounts[aid]["name"]
        if can_block:
            if "unblock" not in ops:
                log("%s: back in the group, but the app can't unblock; lift it by hand" % n)
                continue
            try:
                call("unblock", aid)
            except AdapterError as e:
                failures.append("unblock %s: %s" % (n, e))
                continue
        ours.discard(aid)
        lifted_n += 1
        log("%s: back in the group; sign-in allowed again" % n)

    ours &= set(accounts)
    save_state(ours)
    log("%d blocked, %d allowed again" % (blocked_n, lifted_n))


def publish_names():
    if cfg["namesOut"] is None:
        return
    try:
        held = call("names").get("names")
        if not isinstance(held, list):
            raise AdapterError("adapter names: no names array")
    except AdapterError as e:
        failures.append(str(e))
        return
    held = sorted({str(n).strip().lower() for n in held if str(n).strip()})
    if any(len(n.split()) != 1 for n in held):
        failures.append("adapter names: a name with whitespace in it")
        return
    tmp = cfg["namesOut"] + ".tmp"
    with open(tmp, "w") as f:
        f.write("".join(n + "\n" for n in held))
    os.replace(tmp, cfg["namesOut"])
    log("%d names held" % len(held))


lifecycle()
publish_names()

if failures:
    for f in failures:
        print("%s: failed: %s" % (app, f), file=sys.stderr)
    sys.exit(1)
