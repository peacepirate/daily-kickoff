"""Is the link still there? — a liveness check for the items about to publish.

Link rot cannot be prevented, only not published into. This module asks the
smallest useful question at the latest useful moment.

**Where it runs, and why not anywhere else.** It checks the *selected* items
immediately before an edition is built — not every pool admission. Two reasons,
and the second is the one that matters:

  1. Volume. Seven urls a night against sixty-odd admissions.
  2. Staleness. A candidate can sit in the pool for up to MAX_AGE_DAYS before it
     is chosen, so a check at admission answers a question about a url as it was
     up to two weeks before a reader ever sees it. The only check worth having
     is the one taken at publish time.

**Fail-open on doubt, fail-closed on proof — and never a blocker.** This runs
inside a nightly job that has already lost thirteen nights to a silent stall, so
the design constraint is that it can only ever *subtract items*, never stop the
run. Concretely:

  * every exception is caught, at every level. The module has no code path that
    can raise into a caller;
  * a timeout, a DNS failure, a connection reset, a 403, a 429 or any 5xx is
    `unknown`, and `unknown` publishes. Cloudflare refusing a HEAD from a script
    is not evidence that a reader would see a broken page;
  * only 404 and 410 are `dead`, because only those are the server stating that
    the resource is gone. That is the proof standard, and it is deliberately
    narrow: dropping a live item is a silent editorial loss, and the whole point
    of this module is to avoid the *visible* failure without buying an invisible
    one;
  * there is a total time budget. Past it, everything remaining is `unknown`, so
    a slow network costs the edition seconds, not the night;
  * if EVERY item comes back dead, nothing is dropped. A checker that empties
    the edition is far more likely to be broken — captive portal, hijacked DNS,
    a proxy answering 404 for everything — than to have discovered that all
    seven publishers deleted their posts on the same morning.

The honest cost of that trade: a 403-behind-a-bot-wall url that really is dead
will publish. This module reports what it saw so the case is visible, and it
does not pretend a refusal to answer is an answer.

Pure stdlib plus an optional httpx. No clock of its own beyond a monotonic
budget, and the HTTP client is injectable, so the tests run with no network.
"""
from __future__ import annotations

import time
from pathlib import Path
from urllib.parse import urljoin

try:                                    # normal: scripts/lib is on the path
    from bundle import is_safe_url
except ImportError:                     # imported with only the repo root there
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from bundle import is_safe_url

# The closed vocabulary. `unknown` is not a failure of this module — it is the
# honest answer to "the server would not say", and it is the common case for
# anything behind a bot wall.
VERDICTS = ("alive", "dead", "unknown")

# The proof standard. 404 Not Found and 410 Gone are the server saying the
# resource is not there. 403/401/429 are the server refusing *us*, and 5xx is
# the server being broken today — none of those are link rot.
DEAD_STATUSES = frozenset({404, 410})

# Methods: HEAD, then GET when the server says HEAD is not allowed. 501 is
# included because a handful of servers answer "not implemented" to HEAD rather
# than "method not allowed".
GET_FALLBACK_STATUSES = frozenset({405, 501})

MAX_REDIRECTS = 3          # a few hops, not a crawl
TIMEOUT = 6.0              # per request
BUDGET = 45.0              # for the whole batch
MAX_URLS = 12              # a hard ceiling: this must never become a crawler

# A real User-Agent with a contact surface. A blank or forged one is how a
# nightly script gets an entire domain to start refusing the fetch job too.
USER_AGENT = "daily-kickoff-linkcheck/1.0 (+https://priyesh.fyi; nightly link check)"

HEADERS = {"User-Agent": USER_AGENT, "Accept": "*/*"}


def httpx_client():
    """A redirect-following-disabled httpx client, or None if httpx is absent.

    Redirects are followed by hand below so the chain can be reported and
    bounded. Returning None rather than raising is the fail-open path: no client
    means every verdict is `unknown`, which publishes.
    """
    try:
        import httpx
    except Exception:
        return None
    try:
        return httpx.Client(timeout=TIMEOUT, headers=HEADERS,
                            follow_redirects=False)
    except Exception:
        return None


def _result(url, verdict, status=None, final_url=None, note="", redirects=0):
    return {"url": url, "verdict": verdict, "status": status,
            "final_url": final_url or url, "note": note, "redirects": redirects}


def check_url(url: str, client, max_redirects: int = MAX_REDIRECTS) -> dict:
    """One url, one verdict. Never raises, never follows more than a few hops.

    `client` needs a single method: `request(method, url)` returning an object
    with `.status_code` and `.headers`. That is httpx's shape and it is trivial
    to stub, which is what keeps the test suite off the network.
    """
    try:
        if not is_safe_url(url):
            # Nothing to check: this url must not be published regardless, and
            # handing it to an HTTP client is the one way this module could
            # become the thing that fetches a `file://` path.
            return _result(url, "dead", note="unsafe_url")
        if client is None:
            return _result(url, "unknown", note="client_unavailable")

        current = url
        redirects = 0
        while True:
            resp = client.request("HEAD", current)
            status = getattr(resp, "status_code", None)
            if status in GET_FALLBACK_STATUSES:
                resp = client.request("GET", current)
                status = getattr(resp, "status_code", None)

            if isinstance(status, int) and 300 <= status < 400:
                location = ""
                try:
                    location = (resp.headers or {}).get("location", "") or ""
                except Exception:
                    location = ""
                if not location:
                    # A redirect with nowhere to go. The server is confused, not
                    # the link — this is not proof of rot.
                    return _result(current, "unknown", status, url,
                                   "redirect_without_location", redirects)
                if redirects >= max_redirects:
                    # Could be a consent wall looping a cookie-less client, so
                    # `unknown`, not `dead`.
                    return _result(current, "unknown", status, url,
                                   "redirect_limit", redirects)
                target = urljoin(current, location)
                if not is_safe_url(target):
                    # A redirect into javascript:/data:/a hostless url. The item
                    # cannot be published behind that.
                    return _result(current, "dead", status, target,
                                   "unsafe_redirect", redirects)
                redirects += 1
                current = target
                continue

            if not isinstance(status, int):
                return _result(url, "unknown", None, current,
                               "no_status", redirects)
            if status in DEAD_STATUSES:
                return _result(url, "dead", status, current, "", redirects)
            if status < 400:
                return _result(url, "alive", status, current, "", redirects)
            # 401/403/429/5xx and anything else: the server refused or broke.
            # Not evidence about the link.
            return _result(url, "unknown", status, current,
                           "refused_or_erroring", redirects)
    except Exception as exc:                     # timeouts, DNS, resets, TLS
        return _result(url, "unknown", None, url,
                       f"{type(exc).__name__}: {exc}"[:120])


def check_urls(urls, client=None, budget: float = BUDGET,
               max_urls: int = MAX_URLS, clock=time.monotonic) -> dict:
    """Verdicts for `urls`, keyed by url. Bounded in count and in wall time.

    Duplicates are checked once. Past `max_urls`, or past the time budget, the
    remainder is `unknown` and says so — a truncated check must be visible as a
    truncated check, not silently indistinguishable from a clean one.
    """
    out: dict[str, dict] = {}
    try:
        start = clock()
        seen = []
        for u in urls:
            if u not in seen:
                seen.append(u)
        for i, u in enumerate(seen):
            if i >= max_urls:
                out[u] = _result(u, "unknown", note="over_max_urls")
                continue
            if clock() - start >= budget:
                out[u] = _result(u, "unknown", note="budget_exhausted")
                continue
            out[u] = check_url(u, client)
    except Exception as exc:
        # Belt and braces: the loop itself must not be able to raise into the
        # nightly job either.
        for u in urls:
            out.setdefault(u, _result(u, "unknown", note=f"checker_failed: {exc}"[:120]))
    return out


def filter_dead(rows: list[dict], verdicts: dict) -> tuple[list[dict], list[dict], str]:
    """Apply the publish policy. Returns (kept, dropped, note).

    The policy in one line: drop only what a server said is gone, and only if
    something survives. `note` is one of

      applied        some rows were dropped on proof
      clean          nothing was dead
      inconclusive   every row looked dead, so the checker is not believed
      empty          nothing to check

    `inconclusive` is the kill switch and it is the reason this cannot silently
    publish an empty edition. A day with genuinely nothing to say is a thin day
    the pipeline already has words for; a day emptied by a link checker is a
    link checker malfunction wearing a thin day's clothes.
    """
    if not rows:
        return [], [], "empty"
    dead = [r for r in rows
            if (verdicts.get((r.get("url") or "").strip()) or {}).get("verdict") == "dead"]
    if not dead:
        return list(rows), [], "clean"
    if len(dead) == len(rows):
        return list(rows), [], "inconclusive"
    dead_ids = {id(r) for r in dead}
    return [r for r in rows if id(r) not in dead_ids], dead, "applied"


def report_lines(verdicts: dict) -> list[str]:
    """One line per url, for the nightly log. Ordering is input order."""
    lines = []
    for url, res in verdicts.items():
        bits = [res["verdict"].upper().ljust(7), str(res["status"] or "-").ljust(4), url]
        if res["redirects"]:
            bits.append(f"-> {res['final_url']} ({res['redirects']} hop(s))")
        if res["note"]:
            bits.append(f"[{res['note']}]")
        lines.append("  " + " ".join(bits))
    return lines


# ── CLI ──────────────────────────────────────────────────────────────────────
#
# Standalone so the check can be run by hand against a built edition before
# anything is wired to it, and so a person can see the verdicts on a real day.
#
# Exits 0 on a dead link by design. This is a report, and a non-zero exit from a
# link checker inside `set -e` is exactly the shape of "a network blip stopped
# the day". `--strict` exists for a human at a terminal who wants the exit code.

def _main(argv=None):
    import argparse, json
    ap = argparse.ArgumentParser(description="Liveness check for outbound links")
    ap.add_argument("--edition", help="edition JSON written by feed_edition.py")
    ap.add_argument("--url", action="append", default=[], help="a url (repeatable)")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 if anything is dead (for a human, never for the nightly run)")
    a = ap.parse_args(argv)

    urls = list(a.url)
    if a.edition:
        data = json.loads(Path(a.edition).read_text())
        urls += [i.get("url", "") for i in data.get("items", []) if i.get("url")]
    if not urls:
        ap.error("nothing to check — pass --edition or --url")

    verdicts = check_urls(urls, client=httpx_client())
    for line in report_lines(verdicts):
        print(line)
    counts = {v: sum(1 for r in verdicts.values() if r["verdict"] == v) for v in VERDICTS}
    print(f"  {counts['alive']} alive, {counts['dead']} dead, {counts['unknown']} unknown "
          f"(unknown publishes — only a 404/410 is proof)")
    return 1 if (a.strict and counts["dead"]) else 0


if __name__ == "__main__":
    raise SystemExit(_main())
