#!/bin/bash
# One-time setup: installs a macOS launchd agent that runs the job orchestrator
# at 06:00 every day. Which jobs run is decided per job by `schedule:`.
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

  <!-- One slot: 06:00 every day. Each job gates itself on its own schedule:
       field, so Mon–Sat runs digest jobs and Sunday runs generation.
       The orchestrator holds no day policy at all — and with a single slot per
       day a sunday job cannot fire twice, so no day needs excluding.
       06:00 rather than 23:00 so the Saturday synthesis is read and starred a
       full day before Sunday's generation run consumes it.
       launchd Weekday: 0=Sun, 1=Mon … 6=Sat.
       This heredoc is unquoted: no backticks in this prose, they would run. -->
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>2</integer><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>3</integer><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>4</integer><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>5</integer><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>6</integer><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>
  </array>

  <!-- If the machine was asleep at 06:00, launchd fires this once on wake.
       Degraded (the digest lands when you open the lid) but never lost.
       A pmset repeat wakeorpoweron event makes it deterministic. -->
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
echo "  06:00 every day, local time. Each job gates on its own schedule: field,"
echo "  so Mon-Sat run digest jobs and Sunday runs generation."
echo "  Logs: $LOG_DIR/"
echo ""

# launchd fires a missed calendar job on wake, so a sleeping Mac degrades the
# 06:00 slot to "whenever the lid opens" rather than losing it. A scheduled wake
# makes it deterministic. One wake time covers everything precisely because
# there is only one slot.
# Here-string, not a pipe: under `set -o pipefail`, `grep -q` exits on first
# match and the writer dies of SIGPIPE (141), failing the pipeline even though
# the match succeeded.
if grep -q '05:50' <<<"$(pmset -g sched 2>/dev/null || true)"; then
  echo "  Scheduled wake: already configured (pmset -g sched)."
else
  echo "  RECOMMENDED — wake the Mac just before the run so 06:00 is deterministic:"
  echo "    sudo pmset repeat wakeorpoweron MTWRFSU 05:50:00"
  echo "  Verify with: pmset -g sched"
fi
echo ""
echo "  To test a manual run right now:"
echo "    bash $RUN_SCRIPT"
echo ""
echo "  To uninstall:"
echo "    bash $REPO_DIR/scripts/install-schedule.sh --uninstall"
echo "    sudo pmset repeat cancel"
