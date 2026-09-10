#!/usr/bin/env bash
# fm-cost-report.sh - cost per accepted result across this home's fleet.
#
# Answers "what did each task cost, counting every attempt and its review",
# from local records only: no network call, no live fleet mutation, no write
# anywhere. Output is TOON by default (the axi house style) and the same model
# as JSON under --json (schema fm-cost-report.v1).
#
# Inputs, all read-only:
#   $FM_HOME/data/backlog.md      via `tasks-axi list --file` (id, state, kind,
#                                 repo, since/created and closed dates). REQUIRED.
#   $FM_HOME/data/done-archive.md parsed directly, because tasks-axi does not read
#                                 the archive: "- [x] <id> - ..." lines with
#                                 (repo: R) (kind: K) (since D) and (done D) or
#                                 (reported D); a line without a close date takes
#                                 its "## Archived D" heading date. Optional.
#   $FM_HOME/state/<id>.meta      live tasks: harness, kind, model, worktree.
#   $FM_HOME/state/<id>.status    live tasks: file birth time (st_birthtime,
#                                 where the platform records it) is the earliest
#                                 justified start, because status lines carry no
#                                 timestamp; the last line decides "failed".
#   Claude transcripts            ${FM_COST_CLAUDE_PROJECTS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}
#                                 <slug>/<session>.jsonl plus
#                                 <slug>/<session>/subagents/*.jsonl.
#   Codex sessions                ${FM_COST_CODEX_SESSIONS:-${CODEX_HOME:-$HOME/.codex}/sessions}
#                                 YYYY/MM/DD/rollout-*.jsonl.
#   $FM_HOME/config/model-prices.json  optional price table (below).
# The backlog is required; at least one transcript root must exist. An absent
# single root, archive, or price table is named on the sources line rather than
# guessed around. tasks-axi and python3 are required.
#
# Attribution (which tokens belong to which task):
#   Worker session: a Claude main session or Codex session whose launch brief -
#     the first user message carrying "launch-brief", within its first five user
#     messages - contains the brief's status redirect
#     ">> '<FM_HOME>/state/<id>.status'". The path pins both the task id and this
#     home, so a reused worktree slot or another home's worker never matches, and
#     a sibling task merely mentioned in a brief is never claimed. Claude
#     subagent transcripts inherit their parent session's attribution.
#   Task window: a task record spans [since 00:00, close date 23:59:59] in local
#     time (open end for an open record, open start when since is unknown). A
#     session belongs to the earliest record of its id whose window contains the
#     session's launch-brief timestamp, so a task id reused later splits cleanly.
#     Inside a session, usage records stamped after the window closes are
#     dropped and counted as dropped_after_close. A session no window contains
#     is counted under unattributed and never guessed onto a task.
#   Review: a no-mistakes gate session (Claude slug or Codex cwd under
#     .no-mistakes/worktrees/<repo-hash>-<RUN_ID>, whose checkout is detached so
#     no branch names the task) counts toward the task whose attributed worker
#     transcript mentions RUN_ID earliest: the worker that starts a run sees its
#     id first, and later mentions by other tasks are quotes. A tie is reported
#     as ambiguous and attributed to none.
#   Primary: the firstmate home's own sessions (Claude slug of FM_HOME, Codex cwd
#     equal to FM_HOME) cannot be split per task, so --primary reports them as
#     per-day totals only.
#
# Token classes:
#   Claude: fresh_input=input_tokens, cache_write=cache_creation_input_tokens,
#     cache_read=cache_read_input_tokens, output=output_tokens. One API message
#     repeats across streamed chunks and resumed transcripts, so records are
#     deduped by message.id per task, keeping the largest value of each class.
#   Codex: event_msg token_count payload.info.last_token_usage. A token_count
#     whose total_token_usage equals the previous one is a re-emission and is
#     skipped. input_tokens includes cached and cache-write input, so
#     fresh_input = input - cached_input - cache_write_input; output_tokens
#     already includes reasoning_output_tokens. The model is the latest
#     turn_context model, else session_meta's, else "unknown".
#
# Per-task fields: id, repo, kind, harness, model, outcome, attempts, elapsed_h,
#   the four token classes (worker), review_tokens, cost_usd. The tokens[] block
#   breaks each task down by role (worker or review), source, and model.
#   outcome: failed when the live status file's last line is "failed:"; done for
#     a Done backlog or archive record; in_flight for a live meta or an In flight
#     record; abandoned otherwise (a queued or held record whose worker ran and
#     is gone). Done records carry no structured failure flag, so a failed task
#     that was later closed reads as done.
#   attempts: distinct worker sessions attributed to the task (subagents
#     excluded). A relaunch starts a new session and counts; a harness resume of
#     the same session counts once; transcripts the harness has pruned (Claude's
#     cleanupPeriodDays) or a harness without supported transcripts undercount.
#   elapsed_h: from the earliest of the live status file's birth and the first
#     attributed usage record, to the last attributed usage record, or to now
#     for an in-flight task.
#   A task is listed when it has an attributed worker session or a live meta;
#   --task lists the named ids even with no tokens.
#
# Price table (optional; absent means tokens only and cost_usd "-"):
#   $FM_HOME/config/model-prices.json, example docs/examples/model-prices.json:
#   {"models": {"<exact model id>": {"fresh_input": N, "cache_write": N,
#     "cache_read": N, "output": N}}} in US dollars per million tokens. Model ids
#   match exactly as the transcript records them. A task with tokens on an
#   unlisted model prints cost_usd "-" and names the model under unpriced; a
#   malformed table is an error.
#
# Flags:
#   --since <YYYY-MM-DD>  only tasks open, or closed on or after the date; the
#                         primary block starts at the date
#   --task <id>           only this task (repeatable)
#   --repo <name>         only tasks in this repo
#   --primary             add the primary per-day block
#   --json                JSON instead of TOON
#   -h, --help            this help
# Exit codes: 0 report printed, 1 missing or unreadable input, 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
usage: fm-cost-report.sh [--since <YYYY-MM-DD>] [--task <id>]... [--repo <name>] [--primary] [--json]

Cost per accepted result from local transcripts: per task, the worker and review
tokens by class and model, attempts, elapsed hours, and outcome.
TOON by default, JSON with --json. Read-only; no network.

  --since <date>   only tasks open, or closed on or after the date
  --task <id>      only this task (repeatable)
  --repo <name>    only tasks in this repo
  --primary        add the primary firstmate session totals per day
  --json           print JSON (schema fm-cost-report.v1)

Inputs: $FM_HOME/data/backlog.md (required, via tasks-axi), done-archive.md,
state/<id>.meta and .status, Claude transcripts (FM_COST_CLAUDE_PROJECTS), Codex
sessions (FM_COST_CODEX_SESSIONS), and optional config/model-prices.json in US
dollars per million tokens (example: docs/examples/model-prices.json).
The script header owns attribution, token-class, and outcome rules.
EOF
}

SINCE=""
REPO=""
PRIMARY=0
JSON=0
TASKS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --since)
      [ "$#" -ge 2 ] || { echo "fm-cost-report: --since needs a date" >&2; exit 2; }
      SINCE=$2; shift 2 ;;
    --task)
      [ "$#" -ge 2 ] || { echo "fm-cost-report: --task needs an id" >&2; exit 2; }
      TASKS+=("$2"); shift 2 ;;
    --repo)
      [ "$#" -ge 2 ] || { echo "fm-cost-report: --repo needs a name" >&2; exit 2; }
      REPO=$2; shift 2 ;;
    --primary) PRIMARY=1; shift ;;
    --json) JSON=1; shift ;;
    *) echo "fm-cost-report: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$SINCE" in
  ""|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "fm-cost-report: --since must be YYYY-MM-DD, got: $SINCE" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "fm-cost-report: python3 not found" >&2; exit 1; }
command -v tasks-axi >/dev/null 2>&1 || { echo "fm-cost-report: tasks-axi not found; it reads data/backlog.md" >&2; exit 1; }

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
BACKLOG="$FM_HOME/data/backlog.md"
[ -f "$BACKLOG" ] || { echo "fm-cost-report: missing backlog: $BACKLOG" >&2; exit 1; }

CLAUDE_PROJECTS="${FM_COST_CLAUDE_PROJECTS:-${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/projects}"
CODEX_SESSIONS="${FM_COST_CODEX_SESSIONS:-${CODEX_HOME:-${HOME:-}/.codex}/sessions}"
if [ ! -d "$CLAUDE_PROJECTS" ] && [ ! -d "$CODEX_SESSIONS" ]; then
  echo "fm-cost-report: no transcripts: neither Claude projects ($CLAUDE_PROJECTS) nor Codex sessions ($CODEX_SESSIONS) exists" >&2
  exit 1
fi

if ! BACKLOG_TOON=$(cd "$FM_HOME" && tasks-axi list --file "$BACKLOG" --fields created,closed --limit 1000000 2>&1); then
  echo "fm-cost-report: tasks-axi could not read $BACKLOG: $BACKLOG_TOON" >&2
  exit 1
fi

export FMCR_HOME="$FM_HOME" FMCR_CLAUDE="$CLAUDE_PROJECTS" FMCR_CODEX="$CODEX_SESSIONS"
export FMCR_SINCE="$SINCE" FMCR_REPO="$REPO" FMCR_PRIMARY="$PRIMARY" FMCR_JSON="$JSON"
export FMCR_BACKLOG_TOON="$BACKLOG_TOON"
FMCR_TASKS=$(printf '%s\n' "${TASKS[@]+"${TASKS[@]}"}")
export FMCR_TASKS

exec python3 - <<'PY'
import datetime as dt
import glob
import json
import os
import re
import sys
import time

E = os.environ
HOME = E["FMCR_HOME"].rstrip("/") or "/"
CLAUDE = E["FMCR_CLAUDE"]
CODEX = E["FMCR_CODEX"]
SINCE = E["FMCR_SINCE"]
REPO = E["FMCR_REPO"]
PRIMARY = E["FMCR_PRIMARY"] == "1"
AS_JSON = E["FMCR_JSON"] == "1"
ONLY = [t for t in E["FMCR_TASKS"].split("\n") if t]
CLASSES = ("fresh_input", "cache_write", "cache_read", "output")
ULID = re.compile(r"01[0-9A-HJKMNP-TV-Z]{24}")
REVIEW_CWD = re.compile(r"/\.no-mistakes/worktrees/[0-9a-f]+-(01[0-9A-HJKMNP-TV-Z]{24})/?$")
REVIEW_SLUG = re.compile(r"-no-mistakes-worktrees-[0-9a-f]+-(01[0-9A-HJKMNP-TV-Z]{24})$")
NOW = time.time()


def die(msg):
    sys.stderr.write("fm-cost-report: %s\n" % msg)
    sys.exit(1)


def day_start(d):
    return time.mktime(dt.datetime.strptime(d, "%Y-%m-%d").timetuple())


def day_end(d):
    return day_start(d) + 86400 - 0.001


def ts(s):
    if not s:
        return None
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def local_day(t):
    return time.strftime("%Y-%m-%d", time.localtime(t))


def slug(path):
    return re.sub(r"[/.]", "-", path)


homes = {HOME, os.path.realpath(HOME)}
BRIEF = re.compile(">> '(?:%s)/state/([A-Za-z0-9._-]+?)\\.status'" % "|".join(re.escape(h) for h in homes))

# ---- task records ---------------------------------------------------------


def toon_row(s):
    out, i, n = [], 0, len(s)
    while i <= n:
        if i < n and s[i] == '"':
            j, buf = i + 1, []
            while j < n and s[j] != '"':
                if s[j] == "\\" and j + 1 < n:
                    buf.append(s[j:j + 2])
                    j += 2
                    continue
                buf.append(s[j])
                j += 1
            out.append("".join(buf))
            i = j + 1
            if i >= n:
                break
            i += 1
        else:
            j = s.find(",", i)
            if j < 0:
                out.append(s[i:])
                break
            out.append(s[i:j])
            i = j + 1
    return out


def dated(v):
    return v if v and re.fullmatch(r"\d{4}-\d{2}-\d{2}", v) else None


records = []
fields = None
for line in E["FMCR_BACKLOG_TOON"].splitlines():
    m = re.match(r"^tasks\[\d+\]\{([^}]*)\}:$", line)
    if m:
        fields = m.group(1).split(",")
        continue
    if fields is None:
        continue
    if not line.startswith("  "):
        fields = None
        continue
    row = dict(zip(fields, toon_row(line[2:])))
    if not row.get("id"):
        continue
    records.append({
        "id": row["id"], "state": row.get("state", ""), "kind": row.get("kind") or None,
        "repo": row.get("repo") if row.get("repo") not in ("", "-") else None,
        "since": dated(row.get("created")), "closed": dated(row.get("closed")),
    })

ARCHIVE = os.path.join(HOME, "data", "done-archive.md")
archive_present = os.path.isfile(ARCHIVE)
if archive_present:
    heading = None
    with open(ARCHIVE, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            h = re.match(r"^## Archived (\d{4}-\d{2}-\d{2})", line)
            if h:
                heading = h.group(1)
                continue
            m = re.match(r"^- \[x\] (\S+) - ", line)
            if not m:
                continue

            def last(pat):
                found = re.findall(pat, line)
                return found[-1] if found else None

            closed = last(r"\((?:done|reported) (\d{4}-\d{2}-\d{2})\)") or heading
            if any(r["id"] == m.group(1) and r["closed"] == closed and r["state"] == "done" for r in records):
                continue
            records.append({
                "id": m.group(1), "state": "done", "kind": last(r"\(kind: ([^)]+)\)"),
                "repo": last(r"\(repo: ([^)]+)\)"), "since": last(r"\(since (\d{4}-\d{2}-\d{2})\)"),
                "closed": closed,
            })

STATE = os.path.join(HOME, "state")
metas = {}
for path in glob.glob(os.path.join(STATE, "*.meta")):
    meta = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            k, sep, v = line.rstrip("\n").partition("=")
            if sep:
                meta[k] = v
    metas[os.path.basename(path)[:-5]] = meta


def status_info(tid):
    path = os.path.join(STATE, tid + ".status")
    try:
        st = os.stat(path)
    except OSError:
        return None, None
    birth = getattr(st, "st_birthtime", None)
    lastline = ""
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.strip():
                lastline = line.strip()
    return birth, lastline


for tid, meta in metas.items():
    if not any(r["id"] == tid and r["state"] != "done" for r in records):
        records.append({"id": tid, "state": "in_flight", "kind": None, "repo": None, "since": None, "closed": None})

for r in records:
    r["start"] = day_start(r["since"]) if r["since"] else None
    r["end"] = day_end(r["closed"]) if r["closed"] and r["state"] == "done" else None
    r["sessions"] = {}
    r["usage"] = {}
    r["review"] = {}
    r["runs"] = {}
    r["dropped"] = 0
    r["cwds"] = []
    r["sources"] = set()

by_id = {}
for r in records:
    by_id.setdefault(r["id"], []).append(r)
for rs in by_id.values():
    rs.sort(key=lambda r: r["end"] if r["end"] is not None else float("inf"))


def claim(tid, t):
    for r in by_id.get(tid, []):
        if (r["start"] is None or r["start"] <= t) and (r["end"] is None or t <= r["end"]):
            return r
    return None


unattributed = []

# ---- transcript readers ---------------------------------------------------


def jsonl(path):
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with fh:
        for line in fh:
            try:
                yield line, json.loads(line)
            except ValueError:
                continue


def user_text(rec):
    c = (rec.get("message") or {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(p.get("text", "") for p in c if isinstance(p, dict))
    return ""


def note_runs(r, line, stamp):
    for run in ULID.findall(line):
        if stamp is not None and (run not in r["runs"] or stamp < r["runs"][run]):
            r["runs"][run] = stamp


def add(bucket, key, usage, stamp):
    cur = bucket.get(key)
    if cur is None:
        bucket[key] = dict(usage, ts=stamp)
        return
    for c in CLASSES:
        cur[c] = max(cur[c], usage[c])


def claude_usage(rec):
    u = (rec.get("message") or {}).get("usage") or {}
    return {
        "fresh_input": int(u.get("input_tokens") or 0),
        "cache_write": int(u.get("cache_creation_input_tokens") or 0),
        "cache_read": int(u.get("cache_read_input_tokens") or 0),
        "output": int(u.get("output_tokens") or 0),
    }


def claude_brief(path):
    users = 0
    for _, rec in jsonl(path):
        if rec.get("type") != "user":
            continue
        users += 1
        text = user_text(rec)
        if "launch-brief" in text:
            m = BRIEF.search(text)
            return (m.group(1), ts(rec.get("timestamp"))) if m else (None, None)
        if users >= 5:
            break
    return None, None


def scan_claude_task(paths, r, role, sid_key):
    """Fold Claude usage from paths into record r; worker role also collects run ids."""
    bucket = r["usage"] if role == "worker" else r["review"]
    for path in paths:
        for line, rec in jsonl(path):
            if role == "worker" and "01" in line:
                note_runs(r, line, ts(rec.get("timestamp")))
            if rec.get("type") != "assistant":
                continue
            msg = rec.get("message") or {}
            mid = msg.get("id")
            if not mid or not msg.get("usage"):
                continue
            stamp = ts(rec.get("timestamp"))
            if role == "worker" and r["end"] is not None and stamp is not None and stamp > r["end"]:
                r["dropped"] += 1
                continue
            usage = claude_usage(rec)
            if not any(usage.values()):
                continue
            add(bucket, ("claude", msg.get("model") or "unknown", mid), usage, stamp)
            if role == "worker" and rec.get("cwd") and not r["cwds"]:
                r["cwds"].append(rec["cwd"])
    if role == "worker":
        r["sessions"][sid_key] = True
        r["sources"].add("claude")


def codex_scan(path, header_only):
    """Return (meta, brief-id, brief-ts) and, unless header_only, the usage list."""
    meta, model, brief, brief_ts, users, prev, usage, lines = {}, None, None, None, 0, None, [], []
    for n, (line, rec) in enumerate(jsonl(path)):
        if header_only and n >= 400:
            break
        typ, p = rec.get("type"), rec.get("payload") or {}
        if typ == "session_meta":
            meta = p
            model = model or p.get("model")
        elif typ == "turn_context" and p.get("model"):
            model = p["model"]
        elif typ == "event_msg" and p.get("type") == "user_message" and brief is None and users < 5:
            users += 1
            text = p.get("message") or ""
            if "launch-brief" in text:
                m = BRIEF.search(text)
                brief, brief_ts = (m.group(1), ts(rec.get("timestamp"))) if m else ("", None)
                if header_only:
                    break
        elif typ == "event_msg" and p.get("type") == "token_count" and not header_only:
            info = p.get("info") or {}
            total, last = info.get("total_token_usage"), info.get("last_token_usage")
            if not last or total == prev:
                continue
            prev = total
            cached = int(last.get("cached_input_tokens") or 0)
            cwrite = int(last.get("cache_write_input_tokens") or 0)
            usage.append((ts(rec.get("timestamp")), model or "unknown", {
                "fresh_input": max(int(last.get("input_tokens") or 0) - cached - cwrite, 0),
                "cache_write": cwrite, "cache_read": cached,
                "output": int(last.get("output_tokens") or 0),
            }))
        if not header_only and "01" in line:
            lines.append((ts(rec.get("timestamp")), line))
        if header_only and meta and users >= 5:
            break
    return meta, brief, brief_ts, usage, lines


review_claude = {}  # run id -> [paths]
review_codex = {}   # run id -> [paths]
primary_claude = []
primary_codex = []
home_slugs = {slug(h) for h in homes}

if os.path.isdir(CLAUDE):
    for d in sorted(os.listdir(CLAUDE)):
        full = os.path.join(CLAUDE, d)
        if not os.path.isdir(full):
            continue
        mains = sorted(glob.glob(os.path.join(full, "*.jsonl")))
        if d in home_slugs:
            primary_claude.extend(mains + sorted(glob.glob(os.path.join(full, "*", "subagents", "*.jsonl"))))
            continue
        rm = REVIEW_SLUG.search(d)
        if rm:
            review_claude.setdefault(rm.group(1), []).extend(
                mains + sorted(glob.glob(os.path.join(full, "*", "subagents", "*.jsonl"))))
            continue
        for main in mains:
            tid, t = claude_brief(main)
            if tid is None:
                continue
            r = claim(tid, t) if t is not None else None
            sid = os.path.basename(main)[:-6]
            if r is None:
                unattributed.append({"task": tid, "source": "claude", "session": sid})
                continue
            subs = sorted(glob.glob(os.path.join(full, sid, "subagents", "*.jsonl")))
            scan_claude_task([main] + subs, r, "worker", "claude:" + sid)

if os.path.isdir(CODEX):
    for path in sorted(glob.glob(os.path.join(CODEX, "*", "*", "*", "rollout-*.jsonl"))):
        meta, tid, t, _, _ = codex_scan(path, True)
        cwd = (meta.get("cwd") or "").rstrip("/")
        if cwd in homes:
            primary_codex.append(path)
            continue
        rm = REVIEW_CWD.search(cwd + "/")
        if rm:
            review_codex.setdefault(rm.group(1), []).append(path)
            continue
        if not tid:
            continue
        r = claim(tid, t) if t is not None else None
        sid = meta.get("id") or os.path.basename(path)
        if r is None:
            unattributed.append({"task": tid, "source": "codex", "session": sid})
            continue
        _, _, _, usage, lines = codex_scan(path, False)
        for stamp, line in lines:
            note_runs(r, line, stamp)
        for i, (stamp, model, u) in enumerate(usage):
            if r["end"] is not None and stamp is not None and stamp > r["end"]:
                r["dropped"] += 1
                continue
            add(r["usage"], ("codex", model, "%s#%d" % (sid, i)), u, stamp)
        r["sessions"]["codex:" + sid] = True
        r["sources"].add("codex")
        if cwd and not r["cwds"]:
            r["cwds"].append(cwd)

# ---- review attribution ---------------------------------------------------

mentions = {}
for r in records:
    for run, stamp in r["runs"].items():
        mentions.setdefault(run, []).append((stamp, r))
ambiguous_runs = []
for run in sorted(set(review_claude) | set(review_codex)):
    owners = sorted(mentions.get(run, []), key=lambda m: m[0])
    if not owners:
        continue
    if len(owners) > 1 and owners[0][0] == owners[1][0]:
        ambiguous_runs.append(run)
        continue
    r = owners[0][1]
    if run in review_claude:
        scan_claude_task(review_claude[run], r, "review", None)
    for path in review_codex.get(run, []):
        meta, _, _, usage, _ = codex_scan(path, False)
        sid = meta.get("id") or os.path.basename(path)
        for i, (stamp, model, u) in enumerate(usage):
            add(r["review"], ("codex", model, "%s#%d" % (sid, i)), u, stamp)

# ---- prices ---------------------------------------------------------------

PRICES_PATH = os.path.join(HOME, "config", "model-prices.json")
prices = None
if os.path.exists(PRICES_PATH):
    try:
        with open(PRICES_PATH, encoding="utf-8") as fh:
            prices = json.load(fh)["models"]
        if not isinstance(prices, dict):
            raise ValueError("models is not an object")
        for model, row in prices.items():
            for c in CLASSES:
                if not isinstance(row.get(c), (int, float)) or isinstance(row.get(c), bool):
                    raise ValueError("%s.%s is not a number" % (model, c))
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        die("malformed price table %s: %s" % (PRICES_PATH, exc))


def cost(model, tok):
    if prices is None or model not in prices:
        return None
    return sum(tok[c] * prices[model][c] for c in CLASSES) / 1e6


# ---- assemble -------------------------------------------------------------


def fold(bucket):
    rows = {}
    for (source, model, _), u in bucket.items():
        row = rows.setdefault((source, model), dict({c: 0 for c in CLASSES}, source=source, model=model))
        for c in CLASSES:
            row[c] += u[c]
    return sorted(rows.values(), key=lambda x: -sum(x[c] for c in CLASSES))


def outcome(r, meta, last_status):
    if last_status and last_status.startswith("failed:"):
        return "failed"
    if r["state"] == "done":
        return "done"
    if meta is not None or r["state"] == "in_flight":
        return "in_flight"
    return "abandoned"


since_t = day_start(SINCE) if SINCE else None
out_tasks, unpriced = [], set()
for r in records:
    live = r["id"] in metas and r["state"] != "done"
    meta = metas.get(r["id"]) if live else None
    if not r["sessions"] and meta is None and r["id"] not in ONLY:
        continue
    if ONLY and r["id"] not in ONLY:
        continue
    worker, review = fold(r["usage"]), fold(r["review"])
    repo = r["repo"]
    if not repo and r["cwds"]:
        repo = os.path.basename(r["cwds"][0])
    if not repo and meta and meta.get("project"):
        repo = os.path.basename(meta["project"].rstrip("/"))
    if REPO and repo != REPO:
        continue
    birth, last_status = status_info(r["id"]) if live else (None, None)
    res = outcome(r, meta, last_status)
    stamps = [u["ts"] for u in r["usage"].values() if u["ts"] is not None]
    starts = stamps + ([birth] if birth else [])
    elapsed = None
    if starts:
        end = NOW if res == "in_flight" else (max(stamps) if stamps else None)
        if end is not None:
            elapsed = round(max(end - min(starts), 0) / 3600, 2)
    if since_t is not None and res != "in_flight":
        last_t = r["end"] if r["end"] is not None else (max(stamps) if stamps else None)
        if last_t is None or last_t < since_t:
            continue
    by_model, total_cost, missing = [], 0.0, False
    for role, rows in (("worker", worker), ("review", review)):
        for row in rows:
            c = cost(row["model"], row)
            if c is None:
                missing = True
                unpriced.add(row["model"])
            else:
                total_cost += c
            by_model.append(dict(row, role=role, cost_usd=None if c is None else round(c, 4)))
    tok = {c: sum(row[c] for row in worker) for c in CLASSES}
    models = [row["model"] for row in worker]
    harness = (meta or {}).get("harness") or "+".join(sorted(r["sources"])) or None
    out_tasks.append({
        "id": r["id"], "repo": repo, "kind": (meta or {}).get("kind") or r["kind"],
        "harness": harness, "model": "+".join(models) or (meta or {}).get("model"),
        "outcome": res, "attempts": len(r["sessions"]), "elapsed_h": elapsed,
        "since": r["since"], "closed": r["closed"],
        "tokens": tok, "review_tokens": sum(row[c] for row in review for c in CLASSES),
        "cost_usd": None if prices is None or missing else round(total_cost, 4),
        "dropped_after_close": r["dropped"], "by_model": by_model,
    })

primary = None
if PRIMARY:
    days = {}

    def pday(day, source, model, u):
        if since_t is not None and day_start(day) < since_t:
            return
        row = days.setdefault((day, source, model), dict({c: 0 for c in CLASSES}, day=day, source=source, model=model))
        for c in CLASSES:
            row[c] += u[c]

    seen = set()
    for path in primary_claude:
        for _, rec in jsonl(path):
            msg = rec.get("message") or {}
            if rec.get("type") != "assistant" or not msg.get("id") or msg["id"] in seen:
                continue
            stamp = ts(rec.get("timestamp"))
            u = claude_usage(rec)
            if stamp is None or not any(u.values()):
                continue
            seen.add(msg["id"])
            pday(local_day(stamp), "claude", msg.get("model") or "unknown", u)
    for path in primary_codex:
        _, _, _, usage, _ = codex_scan(path, False)
        for stamp, model, u in usage:
            if stamp is not None:
                pday(local_day(stamp), "codex", model, u)
    primary = []
    for key in sorted(days):
        row = days[key]
        c = cost(row["model"], row)
        if c is None and prices is not None:
            unpriced.add(row["model"])
        primary.append(dict(row, cost_usd=None if c is None else round(c, 4)))

report = {
    "schema": "fm-cost-report.v1",
    "home": HOME,
    "sources": {
        "claude": CLAUDE if os.path.isdir(CLAUDE) else None,
        "codex": CODEX if os.path.isdir(CODEX) else None,
        "archive": ARCHIVE if archive_present else None,
        "prices": PRICES_PATH if prices is not None else None,
    },
    "tasks": out_tasks,
    "primary": primary,
    "unpriced": sorted(unpriced),
    "unattributed": unattributed,
    "ambiguous_review_runs": ambiguous_runs,
}

if AS_JSON:
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    sys.exit(0)


def cell(v):
    if v is None or v == "":
        return "-"
    if isinstance(v, float):
        return "%.4f" % v if v < 100 else "%.2f" % v
    s = str(v)
    if re.search(r'[,":\n]', s) or s != s.strip():
        return json.dumps(s)
    return s


def table(name, cols, rows):
    print("%s[%d]{%s}:" % (name, len(rows), ",".join(cols)))
    for row in rows:
        print("  " + ",".join(cell(row.get(c)) for c in cols))


print("home: %s" % cell(HOME))
print("sources: claude=%s codex=%s archive=%s prices=%s" % tuple(
    cell(report["sources"][k]) if report["sources"][k] else "absent" for k in ("claude", "codex", "archive", "prices")))
if prices is None:
    print("prices: absent, tokens only (add config/model-prices.json, see docs/examples/model-prices.json)")
flat = []
for t in out_tasks:
    row = dict(t, **t["tokens"])
    row["elapsed_h"] = None if t["elapsed_h"] is None else "%.2f" % t["elapsed_h"]
    flat.append(row)
table("tasks", ["id", "repo", "kind", "harness", "model", "outcome", "attempts", "elapsed_h",
                "fresh_input", "cache_write", "cache_read", "output", "review_tokens", "cost_usd"], flat)
tok_rows = [dict(m, task=t["id"]) for t in out_tasks for m in t["by_model"]]
table("tokens", ["task", "role", "source", "model", "fresh_input", "cache_write", "cache_read", "output", "cost_usd"], tok_rows)
dropped = [t for t in out_tasks if t["dropped_after_close"]]
if dropped:
    table("dropped_after_close", ["task", "records"], [{"task": t["id"], "records": t["dropped_after_close"]} for t in dropped])
if primary is not None:
    table("primary", ["day", "source", "model", "fresh_input", "cache_write", "cache_read", "output", "cost_usd"], primary)
if unpriced:
    print("unpriced: %s" % cell(" ".join(sorted(unpriced))))
if unattributed:
    table("unattributed", ["task", "source", "session"], unattributed)
if ambiguous_runs:
    print("ambiguous_review_runs: %s" % " ".join(ambiguous_runs))
print("help[2]:")
print("  Run `fm-cost-report.sh --json` for the full model")
print("  Read the fm-cost-report.sh header for attribution and outcome rules")
PY
