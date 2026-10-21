#!/usr/bin/env python3
"""Third-party notices for the open-source components inside Side.

Writes docs/legal/THIRD_PARTY_NOTICES.md and SIDE/ThirdPartyNotices.txt (shown in About Side),
from each component's own LICENSE file: the Swift packages Xcode resolved (Package.resolved,
checked out in DerivedData) and the grammars vendored in Packages/Alloy. Their licenses
(MIT, BSD-3-Clause) require the notices to ship with the app. Run it after changing a
dependency, and commit what it writes.

    scripts/third-party-notices.py
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOLVED = os.path.join(ROOT, "SIDE.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
# Packages resolved but not linked into Side: swift-argument-parser serves only SwiftTerm's
# command-line tool.
NOT_SHIPPED = {"swift-argument-parser"}
LABELS = {"Sparkle": "MIT, with the licenses of the components it bundles"}


def checkouts():
    found = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/SIDE-*/SourcePackages/checkouts"))
    found += [os.path.join(ROOT, "build/spm/checkouts")]
    return [path for path in found if os.path.isdir(path)]


def license_file(folder):
    for name in ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "COPYING"):
        path = os.path.join(folder, name)
        if os.path.isfile(path):
            return path
    return None


def kind(text):
    head = text[:1500]
    if "Apache License" in head:
        return "Apache-2.0"
    if "Permission is hereby granted, free of charge" in head:
        return "MIT"
    if "Redistribution and use in source and binary forms" in text:
        return "BSD-3-Clause"
    return "see the text below"


def components():
    pins = json.load(open(RESOLVED))["pins"]
    roots = checkouts()
    if not roots:
        sys.exit("No resolved packages found: build Side in Xcode once, then run this again.")
    entries = []
    for pin in sorted(pins, key=lambda p: p["identity"].lower()):
        identity = pin["identity"]
        if identity in NOT_SHIPPED:
            continue
        folder = None
        for root in roots:
            match = [d for d in os.listdir(root) if d.lower() == identity.lower()]
            if match:
                folder = os.path.join(root, match[0])
                break
        path = folder and license_file(folder)
        if not path:
            sys.exit(f"No license file for {identity}")
        text = open(path, encoding="utf-8", errors="replace").read().strip()
        version = pin["state"].get("version") or pin["state"].get("revision", "")[:7]
        name = os.path.basename(folder)
        entries.append((name, version, pin["location"], LABELS.get(name, kind(text)), text))
    for folder in sorted(glob.glob(os.path.join(ROOT, "Packages/Alloy/Sources/TreeSitter*Grammar"))):
        path = license_file(folder)
        if not path:
            continue
        text = open(path, encoding="utf-8", errors="replace").read().strip()
        header = " ".join(open(h).read()[:400] for h in glob.glob(folder + "/include/*.h"))
        match = re.search(r"\(([\w.-]+/[\w.-]+) ([\w.]+)", header)
        source, version = (match.group(1), match.group(2)) if match else (os.path.basename(folder), "")
        name = source.split("/")[-1]
        if any(entry[0].lower() == name.lower() for entry in entries):
            continue
        entries.append((name, version, "https://github.com/" + source if "/" in source else "", kind(text), text))
    return entries


def main():
    entries = components()
    intro = ("Side includes the following open-source components. Each is used under its license, "
             "reproduced in full below with its copyright notices.")
    engines = ("Heron and Alloy, Side's own engines, are published under Apache-2.0 at "
               "github.com/gazishahi/heron and github.com/gazishahi/alloy.")

    markdown = ["# Third-party notices", "", intro, "", engines, "",
                "| Component | Version | License |", "|---|---|---|"]
    markdown += [f"| [{n}]({u}) | {v} | {k} |" if u else f"| {n} | {v} | {k} |" for n, v, u, k, _ in entries]
    for n, v, u, k, t in entries:
        markdown += ["", f"## {n}", ""] + ([u, ""] if u else []) + ["```", t, "```"]
    with open(os.path.join(ROOT, "docs/legal/THIRD_PARTY_NOTICES.md"), "w") as out:
        out.write("\n".join(markdown) + "\n")

    plain = ["Third-party notices", "", intro, "", engines]
    for n, v, u, k, t in entries:
        plain += ["", "", f"{n} {v}".strip() + f" ({k})"] + ([u] if u else []) + ["", t]
    with open(os.path.join(ROOT, "SIDE/ThirdPartyNotices.txt"), "w") as out:
        out.write("\n".join(plain) + "\n")
    print(f"{len(entries)} components")


if __name__ == "__main__":
    main()
