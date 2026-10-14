#!/bin/sh
# Runs package tests with compact output. Usage: Scripts/t.sh [filter]
cd "$(dirname "$0")/../SweepKit" || exit 1
swift test ${1:+--filter "$1"} 2>&1 \
  | grep -E "error:|✘|recorded an issue|Test run with|Build complete" \
  | grep -vE "^Failed frontend command|swift-frontend" | sed -E 's/\x1b\[[0-9;]*m//g' | cut -c1-600 | head -${2:-60}
