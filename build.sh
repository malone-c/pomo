#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p Pomo.app/Contents/MacOS
cp Info.plist Pomo.app/Contents/Info.plist
swiftc -O main.swift -o Pomo.app/Contents/MacOS/Pomo
codesign --force -s - Pomo.app
echo "Built Pomo.app — run with: open Pomo.app"
