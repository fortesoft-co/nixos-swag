"""Tell someone a unit failed, or recovered.

Run by swag-alert-failed@<unit>.service (OnFailure=) and
swag-alert-ok@<unit>.service (OnSuccess=):
  argv[1]   "failed" or "ok"
  argv[2]   JSON config (non-secret): see default.nix

systemd hands the watched unit's name, result and invocation ID over as
MONITOR_UNIT, MONITOR_SERVICE_RESULT and MONITOR_INVOCATION_ID.

One alert per failing streak: a failure while the unit is already marked
failing says nothing, and the first success after it says "recovered".
The marks live in /run, so a unit still failing after a reboot is
reported once more. Delivery is retried for about eight minutes (a
failure early in boot may come before the network); an alert that still
couldn't be sent leaves no mark, so the next failure tries again, and the
alert unit fails (it is never watched itself).
"""

import json
import os
import socket
import subprocess
import sys
import time

sys.stdout.reconfigure(line_buffering=True)

mode = sys.argv[1]
cfg = json.load(open(sys.argv[2]))
unit = os.environ.get("MONITOR_UNIT")
if not unit:
    sys.exit("swag-alert: MONITOR_UNIT is not set; this runs from OnFailure=/OnSuccess=")

host = socket.gethostname()
mark = os.path.join(cfg["stateDir"], unit.replace("/", "_"))
now = time.strftime("%Y-%m-%d %H:%M:%S %Z")


def journal():
    if cfg["journalLines"] == 0:
        return []
    inv = os.environ.get("MONITOR_INVOCATION_ID")
    match = ["_SYSTEMD_INVOCATION_ID=" + inv] if inv else ["-u", unit]
    r = subprocess.run(
        [cfg["journalctl"], "-q", "--no-pager", "-o", "short-iso",
         "-n", str(cfg["journalLines"])] + match,
        stdout=subprocess.PIPE, text=True,
    )
    return r.stdout.splitlines()


RETRY_DELAYS = [5, 15, 30, 60, 120, 240]


def send(event, title, body, extra):
    for delay in RETRY_DELAYS + [None]:
        if deliver(event, title, body, extra):
            return True
        if delay is None:
            return False
        print("trying again in %ds" % delay)
        time.sleep(delay)


def deliver(event, title, body, extra):
    ok = True
    if cfg["apprise"]:
        urls = os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "urls")
        kind = "failure" if event == "failed" else "success"
        r = subprocess.run(
            [cfg["apprise"], "--storage-mode=memory", "-n", kind,
             "-c", urls, "-t", title],
            input=body, text=True,
        )
        if r.returncode != 0:
            print("apprise could not deliver the alert (exit %d)" % r.returncode)
            ok = False
    if cfg["command"]:
        msg = dict(event=event, host=host, unit=unit, at=now, **extra)
        r = subprocess.run(cfg["command"], input=json.dumps(msg), text=True)
        if r.returncode != 0:
            print("the alert command failed (exit %d)" % r.returncode)
            ok = False
    return ok


if mode == "failed":
    if os.path.exists(mark):
        print("%s failed again; already reported" % unit)
        sys.exit(0)
    result = os.environ.get("MONITOR_SERVICE_RESULT", "failed")
    lines = journal()
    body = "%s failed (%s) at %s." % (unit, result, now)
    if lines:
        body += "\n\n" + "\n".join(lines)
    with open(mark, "w") as f:
        json.dump({"since": now}, f)
    if not send("failed", "%s: %s failed" % (host, unit), body,
                {"result": result, "since": now, "lines": lines}):
        os.remove(mark)
        sys.exit(1)
    print("%s failed; reported" % unit)

elif mode == "ok":
    if not os.path.exists(mark):
        sys.exit(0)
    since = json.load(open(mark)).get("since", "?")
    body = "%s works again at %s (failing since %s)." % (unit, now, since)
    if not send("recovered", "%s: %s recovered" % (host, unit), body,
                {"result": "success", "since": since, "lines": []}):
        sys.exit(1)
    os.remove(mark)
    print("%s recovered; reported" % unit)

else:
    sys.exit("swag-alert: unknown mode %r" % mode)
