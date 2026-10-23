#!/usr/bin/env bash
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
# The Azure Ubuntu mirror stalled at a few kB/s during browser dependency
# installation. Use the official signed Ubuntu archive on this disposable runner.
for apt_source in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
  if [ -f "$apt_source" ]; then
    sudo sed -i 's|http://azure.archive.ubuntu.com/ubuntu|https://archive.ubuntu.com/ubuntu|g;s|https://azure.archive.ubuntu.com/ubuntu|https://archive.ubuntu.com/ubuntu|g' "$apt_source"
  fi
done
