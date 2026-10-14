#!/bin/sh
# Builds a throwaway home folder full of fake caches, projects and apps, so
# House Keeping can be exercised end to end without touching the real one.
#
#   Scripts/make-fixture.sh /tmp/housekeeping-home
#   HOUSEKEEPING_HOME=/tmp/housekeeping-home "build/DerivedData/Build/Products/Debug/House Keeping.app/Contents/MacOS/HouseKeeping"
#   HOUSEKEEPING_HOME=/tmp/housekeeping-home housekeeping clean --tier safe --yes
set -e
HOME_DIR="${1:?usage: make-fixture.sh <folder>}"
case "$HOME_DIR" in
  "$HOME"|"$HOME/"|/|/Users|/Users/) echo "refusing to use $HOME_DIR as a fixture"; exit 1 ;;
esac
rm -rf "$HOME_DIR"
mkdir -p "$HOME_DIR"

# fill <relative path> <megabytes>
fill() {
  mkdir -p "$(dirname "$HOME_DIR/$1")"
  dd if=/dev/urandom of="$HOME_DIR/$1" bs=1048576 count="$2" 2>/dev/null
}
small() {
  mkdir -p "$(dirname "$HOME_DIR/$1")"
  printf '%s\n' "${2:-x}" > "$HOME_DIR/$1"
}

mkdir -p "$HOME_DIR/Documents" "$HOME_DIR/Desktop" "$HOME_DIR/Pictures" "$HOME_DIR/Downloads" "$HOME_DIR/.ssh"
small Documents/thesis.txt "do not delete"
small .ssh/id_ed25519 "secret"

# JavaScript
fill .npm/_cacache/content-v2/blob 60
fill Library/Caches/Yarn/v6/blob 40
fill .bun/install/cache/blob 35
fill Library/Caches/node-gyp/20.0.0/node.tar 5
fill Library/Caches/electron/electron.zip 9
fill Library/Caches/ms-playwright/chromium-1100/chrome 50
# Python
fill Library/Caches/pip/http/blob 20
fill .cache/uv/archive-v0/blob 45
small Library/Caches/pipenv/tiny
fill .cache/huggingface/hub/models--meta--llama/blobs/weights 30
fill .cache/huggingface/hub/models--openai--whisper/blobs/weights 12
# Apple
fill Library/Developer/Xcode/DerivedData/Sweep-abcdefgh/Build/Products/app.o 40
fill Library/Developer/Xcode/DerivedData/Notes-ijklmnop/Build/Products/app.o 15
fill "Library/Developer/Xcode/Archives/2026-09-30/Sweep 30-09-2026.xcarchive/dSYMs/app.dSYM" 20
fill Library/Caches/org.swift.swiftpm/repositories/blob 3
fill Library/Caches/CocoaPods/Pods/blob 25
fill "Library/Developer/Xcode/iOS DeviceSupport/17.4 (21E213)/Symbols/dyld" 14
fill "Library/Developer/Xcode/iOS DeviceSupport/18.1 (22B83)/Symbols/dyld" 14
# JVM, editors, Rust, other
fill .gradle/caches/modules-2/blob 30
fill .m2/repository/org/blob.jar 11
fill Library/Caches/JetBrains/IntelliJIdea2024.1/index 18
fill "Library/Application Support/Code/CachedData/blob" 8
fill .cargo/registry/cache/index.crates.io/serde.crate 12
fill Library/Caches/Homebrew/downloads/bottle.tar.gz 22

# AI agents: old sessions (dated back below) next to a live one
fill .claude/shell-snapshots/snapshot-zsh-old.sh 2
fill .claude/shell-snapshots/snapshot-zsh-live.sh 1
fill .claude/file-history/11111111-aaaa-bbbb-cccc-000000000001/main.swift@v1 14
fill .claude/file-history/22222222-aaaa-bbbb-cccc-000000000002/main.swift@v1 3
fill .claude/projects/-Users-me-code-web/11111111-aaaa-bbbb-cccc-000000000001.jsonl 22
fill .claude/projects/-Users-me-code-web/22222222-aaaa-bbbb-cccc-000000000002.jsonl 5
small .claude/projects/-Users-me-code-web/memory/MEMORY.md "keep me"
fill "Library/Application Support/Claude/Cache/Cache_Data/blob" 26
fill .codex/shell_snapshots/old.sh 2
fill .codex/sessions/2026/07/04/rollout-2026-07-04T10-00-00-aaaa.jsonl 40
fill .codex/sessions/2026/10/12/rollout-2026-10-12T10-00-00-bbbb.jsonl 6
fill .codex/worktrees/old-experiment/app/main.swift 12
fill .codex/generated_images/render-001.png 8
fill .gemini/tmp/abc123/logs.json 4
for old in .claude/shell-snapshots/snapshot-zsh-old.sh .claude/file-history/11111111-aaaa-bbbb-cccc-000000000001 \
    .claude/projects/-Users-me-code-web/11111111-aaaa-bbbb-cccc-000000000001.jsonl .codex/shell_snapshots/old.sh \
    .codex/sessions/2026/07/04 .codex/worktrees/old-experiment .gemini/tmp/abc123; do
  find "$HOME_DIR/$old" -exec touch -t 202607040900 {} +
done

# Projects
small code/web/package.json '{"name":"web"}'
fill code/web/node_modules/react/index.js 30
fill code/web/.next/cache/blob 8
small code/web/src/index.js
small code/api/pyproject.toml
small code/api/.venv/pyvenv.cfg
fill code/api/.venv/lib/site-packages/blob 20
small code/api/app/main.py
small code/old-tool/Cargo.toml
fill code/old-tool/target/debug/old-tool 25
small code/old-tool/src/main.rs
touch -t 202607010900 "$HOME_DIR/code/old-tool/Cargo.toml" "$HOME_DIR/code/old-tool/src/main.rs" "$HOME_DIR/code/old-tool/src" "$HOME_DIR/code/old-tool/target" "$HOME_DIR/code/old-tool"

# System junk
fill Library/Caches/com.example.Notes/Cache.db 16
fill Library/Caches/com.example.Player/Data/blob 28
fill Library/Logs/Example/app.log 6
fill Library/Logs/DiagnosticReports/Example-2026-10-01.ips 1
fill Downloads/OldInstaller.dmg 18
touch -t 202606010900 "$HOME_DIR/Downloads/OldInstaller.dmg"
fill Downloads/Fresh.dmg 7
fill .Trash/old-file.bin 9
small Desktop/.DS_Store
small code/.DS_Store

# Apps for Uninstall. The names are made up so nobody mistakes them for real installs.
app() { # name bundle-id megabytes
  mkdir -p "$HOME_DIR/Applications/$1.app/Contents/MacOS"
  cat > "$HOME_DIR/Applications/$1.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundleShortVersionString</key><string>2.4.1</string>
<key>CFBundleExecutable</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  fill "Applications/$1.app/Contents/MacOS/$1" "$3"
}
app "Example Notes" com.example.Notes 24
app "Example Player" com.example.Player 48
fill "Library/Application Support/com.example.Notes/store.db" 6
small Library/Preferences/com.example.Notes.plist
small "Library/Saved Application State/com.example.Notes.savedState/data"
fill "Library/Application Support/com.gone.Uninstalled/leftover.db" 10
small Library/Preferences/com.gone.Uninstalled.plist

# A little history
mkdir -p "$HOME_DIR/Library/Logs/House Keeping"
python3 - "$HOME_DIR/Library/Logs/House Keeping/operations.jsonl" <<'PY'
import json, sys, uuid, datetime
now = datetime.datetime.now(datetime.timezone.utc)
rows = [(2, "devCaches", [("npm", "npm", 4_200_000_000), ("uv", "uv", 1_300_000_000), ("homebrew", "Homebrew", 600_000_000)]),
        (9, "devCaches", [("xcode-deriveddata", "Xcode DerivedData", 11_800_000_000), ("pip", "pip", 400_000_000)]),
        (16, "projects", [("/code/web", "web", 2_100_000_000)]),
        (30, "devCaches", [("yarn", "Yarn 1", 6_500_000_000), ("cocoapods", "CocoaPods", 2_700_000_000)]),
        (44, "junk", [("user-caches", "User caches", 3_300_000_000)])]
with open(sys.argv[1], "w") as f:
    for days, kind, entries in reversed(rows):
        date = (now - datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
        op = {"id": str(uuid.uuid4()).upper(), "date": date, "kind": kind, "source": "menubar", "dryRun": False,
              "entries": [{"id": str(uuid.uuid4()).upper(), "itemID": i, "itemName": n, "target": "~/" + i, "bytes": b,
                           "mode": "permanent", "result": "removed"} for i, n, b in entries]}
        f.write(json.dumps(op) + "\n")
PY
echo "Fixture home ready at $HOME_DIR ($(du -sh "$HOME_DIR" | cut -f1))"
