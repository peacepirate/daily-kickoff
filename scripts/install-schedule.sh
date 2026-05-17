#!/bin/bash
# One-time setup: installs a macOS launchd agent that runs all digest topics
# at 11:00 PM every night (Mon–Sat; Sundays skipped by run-all-topics.sh).
#
# Usage: bash scripts/install-schedule.sh
# To uninstall: bash scripts/install-schedule.sh --uninstall

set -euo pipefail

LABEL="fyi.priyesh.daily-digest"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SCRIPT="$REPO_DIR/scripts/run-all-topics.sh"
LOG_DIR="$REPO_DIR/scripts/logs"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Uninstalled launchd agent: $LABEL"
  exit 0
fi

chmod +x "$RUN_SCRIPT"
mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${RUN_SCRIPT}</string>
  </array>

  <!-- Fire at 11:00 PM every night; run-all-topics.sh skips Sundays itself -->
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>23</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>

  <!-- If the machine was asleep at 11pm, fire as soon as it wakes -->
  <key>RunAtLoad</key>
  <false/>

  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd-stderr.log</string>

  <!-- Retry up to 3 times if it crashes -->
  <key>ThrottleInterval</key>
  <integer>300</integer>
</dict>
</plist>
EOF

# Load (or reload) the agent
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

echo ""
echo "✓ Installed: $LABEL"
echo "  Fires daily at 11:00 PM local time (Sundays skipped)."
echo "  Logs: $LOG_DIR/"
echo ""
echo "  To test a manual run right now:"
echo "    bash $RUN_SCRIPT"
echo ""
echo "  To uninstall:"
echo "    bash $REPO_DIR/scripts/install-schedule.sh --uninstall"
