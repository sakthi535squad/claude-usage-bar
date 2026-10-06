#!/bin/bash
# Builds into build/preview without installing, then screenshots each theme's
# real menu on demo data: ./preview.sh [out-dir] [theme...]
# Needs Screen Recording permission for the terminal running it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/preview/ClaudeUsage.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -framework Cocoa -lsqlite3 -o "$APP/Contents/MacOS/ClaudeUsage" Sources/*.swift
sed -n '/<?xml/,/^<\/plist>/p' build.sh > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null || true

OUT="${1:-build/screenshots}"
mkdir -p "$OUT"
shift || true
THEMES=("${@:-classic terminal htop claude}")
for theme in ${THEMES[@]}; do
    "$APP/Contents/MacOS/ClaudeUsage" --demo -theme "$theme" --snapshot "$OUT/$theme.png"
done
