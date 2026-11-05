#!/usr/bin/env python3
"""
ClassPulse IoT - Auto Version Bumper
Increments pubspec.yaml version (e.g., 1.0.0+1 -> 1.0.1+2)
Supports patch, minor, major, and build-only increments.
"""

import sys
import os
import re
import argparse

def find_pubspec_path():
    # Look in current dir, Classroom dir, or parent dirs
    candidates = [
        os.path.join(os.getcwd(), 'pubspec.yaml'),
        os.path.join(os.getcwd(), 'Classroom', 'pubspec.yaml'),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'pubspec.yaml'),
    ]
    for p in candidates:
        if os.path.isfile(p):
            return os.path.abspath(p)
    return None

def bump_version(bump_type="patch", dry_run=False):
    pubspec_path = find_pubspec_path()
    if not pubspec_path:
        print("Error: pubspec.yaml not found", file=sys.stderr)
        return None

    with open(pubspec_path, 'r', encoding='utf-8') as f:
        content = f.read()

    match = re.search(r'^version:\s*(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?', content, re.MULTILINE)
    if not match:
        print(f"Error: Could not find valid 'version: x.y.z+b' pattern in {pubspec_path}", file=sys.stderr)
        return None

    major = int(match.group(1))
    minor = int(match.group(2))
    patch = int(match.group(3))
    build = int(match.group(4)) if match.group(4) else 1

    old_version = f"{major}.{minor}.{patch}+{build}"

    if bump_type == "major":
        major += 1
        minor = 0
        patch = 0
        build += 1
    elif bump_type == "minor":
        minor += 1
        patch = 0
        build += 1
    elif bump_type == "patch":
        patch += 1
        build += 1
    elif bump_type == "build":
        build += 1

    new_version = f"{major}.{minor}.{patch}+{build}"

    if dry_run:
        print(f"Dry run: {old_version} -> {new_version}")
        return new_version

    new_content = re.sub(
        r'^version:\s*.*$',
        f'version: {new_version}',
        content,
        flags=re.MULTILINE
    )

    with open(pubspec_path, 'w', encoding='utf-8') as f:
        f.write(new_content)

    print(f"Version bumped: {old_version} -> {new_version} in {pubspec_path}")
    return new_version

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Auto bump Flutter app version")
    parser.add_argument("--type", choices=["patch", "minor", "major", "build"], default="patch",
                        help="Increment type (default: patch + build)")
    parser.add_argument("--dry-run", action="store_true", help="Print new version without modifying file")
    args = parser.parse_args()

    result = bump_version(bump_type=args.type, dry_run=args.dry_run)
    if not result:
        sys.exit(1)

