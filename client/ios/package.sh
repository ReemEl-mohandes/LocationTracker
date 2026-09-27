#!/usr/bin/env bash
# Builds the app with xtool (in WSL) and drops an unsigned .ipa on the Windows Desktop,
# ready for a sideloading tool to sign and install.
# Usage (from WSL):  ./package.sh
set -euo pipefail

cd "$(dirname "$0")"
DEST="/mnt/c/Users/Reeme/Desktop/LocationTrackerClient.ipa"

xtool dev build
python3 mkipa.py
cp xtool/LocationTrackerClient.ipa "$DEST"

echo "Ready: $DEST"
