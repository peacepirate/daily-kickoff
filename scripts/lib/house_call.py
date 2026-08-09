"""The one impure piece of E8 — invoking the model and handing back its stdout.

Deliberately its own module and deliberately tiny. Everything that decides
whether a summary is publishable lives in house_voice.py, which is pure, has no
network and no clock, and runs its whole suite in a second. This file exists so
that separation survives contact with a subprocess.

**It never raises.** A model that times out, refuses, or is not installed returns
"" and every card falls to the publisher's own summary. The edition still
publishes. That is the ladder working, not the ladder failing.
"""
from __future__ import annotations

import os
import shutil
import subprocess

DEFAULT_MODEL = "claude-sonnet-5"

# Seven items of a few thousand characters each. A generous ceiling that is still
# a ceiling: a hung call with no timeout costs the whole night, and the night is
# worth more than any one edition's top rung.
TIMEOUT = 300

# launchd runs with a minimal PATH. Appended, never prepended — prepending these
# once shadowed a test's stub with the real CLI, which meant every suite that
# believed it was hermetic was spending real money.
_EXTRA_PATH = ["/opt/homebrew/bin", "/usr/local/bin",
               os.path.expanduser("~/.npm-global/bin"),
               os.path.expanduser("~/.local/bin")]


def find_claude() -> str:
    """KICKOFF_CLAUDE_BIN wins over PATH, so a test's stub cannot be bypassed."""
    explicit = os.environ.get("KICKOFF_CLAUDE_BIN", "")
    if explicit:
        return explicit
    path = os.pathsep.join([os.environ.get("PATH", "")] + _EXTRA_PATH)
    return shutil.which("claude", path=path) or ""


def call_model(prompt: str, model: str = DEFAULT_MODEL,
               timeout: int = TIMEOUT) -> tuple[str, str]:
    """(stdout, note). `note` is "ok", or why nothing came back.

    Returns rather than raises for every failure — see the module docstring.
    """
    binary = find_claude()
    if not binary:
        return "", "claude CLI not found"
    try:
        proc = subprocess.run(
            [binary, "--dangerously-skip-permissions", "--print",
             "--model", model, prompt],
            capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "", f"timed out after {timeout}s"
    except OSError as exc:
        return "", f"{type(exc).__name__}: {exc}"
    # A non-zero exit still gets its stdout parsed. A refusal and a partial
    # stream both exit non-zero, and a partial stream can still hold a valid
    # array — while the parser and the validator refuse anything that is not one.
    if proc.returncode != 0:
        return proc.stdout or "", f"claude exited {proc.returncode}"
    return proc.stdout or "", "ok"
