#!/bin/bash
# One-time setup: installs a macOS launchd agent that runs the job orchestrator
# at 11:00 PM every night. Which jobs run is decided per job by `schedule:`.
#
# Usage: bash scripts/install-schedule.sh
# To uninstall: bash scripts/install-schedule.sh --uninstall

set -euo pipefail

LABEL="fyi.priyesh.daily-digest"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SCRIPT="$REPO_DIR/scripts/run-jobs.sh"
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

  <!-- Two slots; each job additionally gates itself on its own schedule:
         Mon–Sat 23:00  digest fetch  (weekdays, saturday)
         Sun     04:00  generation    (sunday) — reads Saturday's synthesis
       Sunday is deliberately absent from the 23:00 slot so a sunday job cannot
       fire twice in one day. launchd Weekday: 0=Sun, 1=Mon … 6=Sat. -->
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>23</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>2</integer><key>Hour</key><integer>23</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>3</integer><key>Hour</key><integer>23</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>4</integer><key>Hour</key><integer>23</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>5</integer><key>Hour</key><integer>23</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>6</integer><key>Hour</key><integer>23</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>4</integer><key>Minute</key><integer>0</integer></dict>
  </array>

  <!-- If the machine was asleep at 11pm, fire as soon as it wakes -->
  <key>RunAtLoad</key>
  <false/>

  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd-stderr.log</string>

  <!-- Minimum seconds between respawns. Not a retry policy: without KeepAlive
       launchd does not relaunch on failure, which is intended here. -->
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
echo "  Mon-Sat 23:00 (digest fetch) and Sun 04:00 (generation), local time."
echo "  Each job additionally gates on its own schedule: field in its config."
echo "  Logs: $LOG_DIR/"
echo ""
echo "  To test a manual run right now:"
echo "    bash $RUN_SCRIPT"
echo ""
echo "  To uninstall:"
echo "    bash $REPO_DIR/scripts/install-schedule.sh --uninstall"
