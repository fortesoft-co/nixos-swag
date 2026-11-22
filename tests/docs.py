"""Check the docs against the options and themselves (see docs.nix).

argv[1]  directory with README.md and docs/
argv[2]  JSON list of {"page", "written"}: every option and where it belongs
"""

import json
import os
import re
import sys

root, expected = sys.argv[1], sys.argv[2]
problems = []

pages = {"README.md": open(os.path.join(root, "README.md")).read()}
for f in sorted(os.listdir(os.path.join(root, "docs"))):
    if f.endswith(".md"):
        pages["docs/" + f] = open(os.path.join(root, "docs", f)).read()

for o in json.load(open(expected)):
    page = "docs/" + o["page"]
    if page not in pages:
        problems.append("%s: missing (for option %s)" % (page, o["written"]))
    elif "`%s`" % o["written"] not in pages[page]:
        problems.append("%s: option `%s` is not documented" % (page, o["written"]))


def without_code(text):
    return re.sub(r"```.*?```", "", text, flags=re.S)


def anchors(text):
    # GitHub's heading slugs: lowercase, punctuation dropped, spaces to '-'.
    out = set()
    for h in re.findall(r"^#+ (.+)$", without_code(text), flags=re.M):
        h = re.sub(r"[`*_]", "", h).strip().lower()
        out.add(re.sub(r"[^\w\- ]", "", h).replace(" ", "-"))
    return out


for page, text in pages.items():
    for target in re.findall(r"\]\(([^)\s]+)\)", without_code(text)):
        if re.match(r"[a-z]+:", target):
            continue
        path, _, anchor = target.partition("#")
        dest = os.path.normpath(os.path.join(os.path.dirname(page), path)) if path else page
        if dest not in pages:
            if not os.path.exists(os.path.join(root, dest)):
                problems.append("%s: link to %s: no such page" % (page, target))
            continue
        if anchor and anchor not in anchors(pages[dest]):
            problems.append("%s: link to %s: no such heading" % (page, target))

for p in problems:
    print(p)
if problems:
    sys.exit(1)
print("docs: %d pages, every option documented, every link resolves" % len(pages))
