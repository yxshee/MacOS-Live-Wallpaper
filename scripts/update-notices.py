#!/usr/bin/env python3
"""Regenerates THIRD_PARTY_NOTICES.md and Scenes/NONCOMMERCIAL.md from the scene manifests.

Run it after adding, removing or re-licensing a scene:  python3 scripts/update-notices.py
With --check it changes nothing and exits 1 if the files are out of date (used in CI).
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
STYLES = [("nature", "Nature"), ("stylised", "Stylised"), ("abstract", "Abstract"),
          ("cosy", "Cosy"), ("scifi", "Sci-Fi"), ("other", "Other")]


def scenes():
    found = []
    for manifest in sorted((ROOT / "Scenes").glob("*/scene.json")):
        data = json.loads(manifest.read_text())
        data["id"] = manifest.parent.name
        found.append(data)
    return found


def row(s):
    author = s.get("author", "")
    return f"| [{s['title']}](Scenes/{s['id']}/) | {author} | `{s['licence']}` | [original]({s.get('source', '')}) |"


def notices(all_scenes):
    out = ["# Third-party notices", "",
           "The app's own code is under the MIT licence (see [LICENSE](LICENSE)).",
           "",
           "The scenes below were written by other people and are included under their own licences. "
           "Each scene's folder holds its licence text, its credit and a note of what was changed in porting it. "
           "This file is generated from the scene manifests by `scripts/update-notices.py`.", ""]
    nc = [s for s in all_scenes if "-NC" in s["licence"].upper()]
    if nc:
        out += [f"{len(nc)} of them may not be used commercially; they are listed in "
                "[Scenes/NONCOMMERCIAL.md](Scenes/NONCOMMERCIAL.md) and are left out of builds made with "
                "`scripts/build-app.sh --permissive-only`.", ""]
    for key, title in STYLES:
        group = sorted((s for s in all_scenes if s.get("style", "other") == key), key=lambda s: s["title"].lower())
        if not group:
            continue
        out += [f"## {title}", "", "| Scene | Author | Licence | Source |", "|---|---|---|---|"]
        out += [row(s) for s in group]
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def noncommercial(all_scenes):
    nc = sorted((s for s in all_scenes if "-NC" in s["licence"].upper()), key=lambda s: s["title"].lower())
    out = ["# Scenes that may not be used commercially", "",
           "These scenes are under Creative Commons non-commercial licences. You may use, share and adapt them "
           "with credit, for non-commercial purposes only, and adaptations must carry the same licence. "
           "The versions here are adaptations (ports to Metal Shading Language) offered under those same licences.",
           "",
           "This app is free and carries no advertising, which is why it may include them. If you reuse this "
           "project in anything commercial, build with `scripts/build-app.sh --permissive-only`, which leaves "
           "these folders out, or delete them.", ""]
    if nc:
        out += ["| Scene | Author | Licence | Source |", "|---|---|---|---|"]
        out += [row(s).replace("](Scenes/", "](") for s in nc]
    else:
        out.append("There are none at the moment.")
    return "\n".join(out).rstrip() + "\n"


def main():
    all_scenes = scenes()
    targets = {ROOT / "THIRD_PARTY_NOTICES.md": notices(all_scenes),
               ROOT / "Scenes" / "NONCOMMERCIAL.md": noncommercial(all_scenes)}
    stale = [p for p, text in targets.items() if not p.exists() or p.read_text() != text]
    if "--check" in sys.argv:
        for p in stale:
            print(f"{p.relative_to(ROOT)} is out of date: run python3 scripts/update-notices.py", file=sys.stderr)
        sys.exit(1 if stale else 0)
    for p, text in targets.items():
        p.write_text(text)
    print(f"{len(all_scenes)} scenes; wrote {', '.join(str(p.relative_to(ROOT)) for p in targets)}")


if __name__ == "__main__":
    main()
