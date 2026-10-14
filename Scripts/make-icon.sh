#!/bin/sh
# Redraws the app icon into HouseKeeping/Assets.xcassets and docs/icon.png.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/make-icon" HouseKeeping/MenuBar/WitchIcon.swift Scripts/make-icon/main.swift
"$TMP/make-icon"
