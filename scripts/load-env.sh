#!/bin/sh
# Loads .env (gitignored — see .env.example) into both the current shell and the user's launchd
# environment.
#
# Why launchctl and not just `export`: `xcodebuild` run from this shell would already see an
# `export`ed var, but Xcode.app opened from Finder/Spotlight/Dock is a GUI process that does NOT
# inherit this shell's environment — only the user's launchd environment. `launchctl setenv`
# fixes that, so Demo/Resources/Info.plist's $(MONITORING_API_KEY) substitution resolves
# correctly regardless of how you launch Xcode. It persists until logout/reboot or
# `launchctl unsetenv MONITORING_API_KEY` — run this script again any time the value changes.
#
# Usage: source scripts/load-env.sh   (must be sourced, not executed, to export into this shell)

set -eu

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "No .env file at $ENV_FILE — copy .env.example to .env and fill in real values first." >&2
  return 1 2>/dev/null || exit 1
fi

while IFS='=' read -r key value; do
  case "$key" in
    ''|'#'*) continue ;;
  esac
  export "$key=$value"
  launchctl setenv "$key" "$value"
  echo "Set $key (current shell + launchctl, for GUI-launched Xcode)"
done < "$ENV_FILE"
