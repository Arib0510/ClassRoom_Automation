#!/usr/bin/env python3
"""
Sets up the git pre-commit hook in the repository root.
"""
import os
import shutil

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
HOOK_SRC = os.path.join(ROOT_DIR, '.git', 'hooks', 'pre-commit')

def setup():
    hooks_dir = os.path.join(ROOT_DIR, '.git', 'hooks')
    if not os.path.isdir(hooks_dir):
        print(f"Git hooks directory not found at {hooks_dir}")
        return

    content = """#!/bin/sh
# Git pre-commit hook: Auto bump Flutter version when Classroom/ app files are modified
STAGED_APP_FILES=$(git diff --cached --name-only | grep -E '^Classroom/' | grep -v 'Classroom/pubspec.yaml')
if [ -n "$STAGED_APP_FILES" ]; then
    echo "[Auto-Version] Classroom app files detected in commit. Auto-incrementing version..."
    python Classroom/scripts/bump_version.py 2>/dev/null || py -3 Classroom/scripts/bump_version.py 2>/dev/null || python3 Classroom/scripts/bump_version.py 2>/dev/null
    if [ $? -eq 0 ]; then
        git add Classroom/pubspec.yaml
        echo "[Auto-Version] Successfully bumped version in Classroom/pubspec.yaml and staged for commit."
    fi
fi
"""
    dest = os.path.join(hooks_dir, 'pre-commit')
    with open(dest, 'w', encoding='utf-8', newline='\n') as f:
        f.write(content)
    print(f"Installed pre-commit hook to {dest}")

if __name__ == '__main__':
    setup()

