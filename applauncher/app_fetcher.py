#!/usr/bin/env python3
"""Scan .desktop files and output JSON for the 3D app launcher."""
import json
import os
import glob
import sys
import configparser

DESKTOP_DIRS = [
    "/usr/share/applications",
    "/usr/local/share/applications",
    os.path.expanduser("~/.local/share/applications"),
    "/var/lib/flatpak/exports/share/applications",
    os.path.expanduser("~/.local/share/flatpak/exports/share/applications"),
]


def parse_desktop(path):
    """Parse a .desktop file and return (name, icon, exec) or None."""
    try:
        cp = configparser.ConfigParser(interpolation=None)
        cp.read(path, encoding="utf-8")
        if not cp.has_section("Desktop Entry"):
            return None
        de = cp["Desktop Entry"]
        if de.get("NoDisplay", "false").lower() == "true":
            return None
        if de.get("Type", "") != "Application":
            return None
        name = de.get("Name", "")
        icon = de.get("Icon", "")
        exec_cmd = de.get("Exec", "")
        if not name or not exec_cmd:
            return None
        return {
            "name": name,
            "icon": icon,
            "exec": exec_cmd,
        }
    except Exception:
        return None


def main():
    # Handle --log <appname> (usage tracking, just logs to stderr)
    if len(sys.argv) > 2 and sys.argv[1] == "--log":
        print(f"LAUNCH: {sys.argv[2]}", file=sys.stderr)
        return

    apps = []
    seen_names = set()

    for d in DESKTOP_DIRS:
        if not os.path.isdir(d):
            continue
        for fpath in sorted(glob.glob(os.path.join(d, "*.desktop"))):
            entry = parse_desktop(fpath)
            if entry and entry["name"] not in seen_names:
                seen_names.add(entry["name"])
                apps.append(entry)

    print(json.dumps(apps))


if __name__ == "__main__":
    main()
