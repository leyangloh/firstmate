#!/usr/bin/env bash
# Behavior tests for bin/fm-cost-report.sh: per-task cost from fixture Claude
# and Codex transcripts. Covers message-id dedupe, launch-brief attribution to
# the right task and home across a reused worktree slot, the task time-window
# bound, relaunch attempts, subagent and no-mistakes review folding, Codex
# token_count re-emission, the archive path, filters, the tokens-only path
# without a price table, the priced path with one, the primary per-day block,
# and plain failures on missing inputs.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

REPORT="$ROOT/bin/fm-cost-report.sh"
T=$(fm_test_tmproot fm-cost-report)
H="$T/home"
CL="$T/claude"
CX="$T/codex"
RUN=01J8Y3K5N6P7Q8R9S0T1V2W3X4
export TZ=UTC

slug() { printf '%s' "$1" | tr '/.' '--'; }

brief() {  # <file> <ts> <home> <task>
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"\\u2063FIRSTMATE_OP: v1 launch-brief: You are a crewmate.\\n4. Report status: echo line >> '"'"'%s/state/%s.status'"'"'\\nSibling context: %s/state/other-task.status"}}\n' \
    "$2" "$3" "$4" "$3" >> "$1"
}

asst() {  # <file> <ts> <msg-id> <model> <fresh> <cache-write> <cache-read> <output> [text]
  printf '{"type":"assistant","timestamp":"%s","cwd":"/wt/widget-abc/1/widget","message":{"id":"%s","model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s},"content":[{"type":"text","text":"%s"}]}}\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${9:-ok}" >> "$1"
}

codex_tok() {  # <file> <ts> <total-input> <input> <cached> <cache-write> <output>
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s},"last_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"cache_write_input_tokens":%s,"output_tokens":%s,"reasoning_output_tokens":3}}}}\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" >> "$1"
}

# --- fixture home --------------------------------------------------------------
mkdir -p "$H/data" "$H/state" "$H/config"
cat > "$H/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] task-b - fix B (repo: widget) (kind: ship) (since 2026-09-05)

## Queued

## Done
- [x] task-a - fix A (repo: widget) (kind: ship) (since 2026-09-01) (done 2026-09-01)
- [x] task-d - fix D (repo: widget) (kind: ship) (since 2026-09-08) (done 2026-09-09)
EOF
cat > "$H/data/done-archive.md" <<'EOF'
# Done archive

## Archived 2026-08-20
- [x] task-c - old C (repo: gadget) (kind: scout) (done 2026-08-20)
EOF
printf 'harness=claude\nkind=ship\nmodel=opus\nworktree=/wt/widget-abc/1/widget\n' > "$H/state/task-b.meta"
printf 'working: setup done\n' > "$H/state/task-b.status"

# --- Claude transcripts --------------------------------------------------------
W1="$CL/$(slug /wt/widget-abc/1/widget)"
W2="$CL/$(slug /wt/widget-abc/2/widget)"
G1="$CL/$(slug /wt/gadget-def/1/gadget)"
RV="$CL/$(slug "/u/.no-mistakes/worktrees/abc123-$RUN")"
PR="$CL/$(slug "$H")"
mkdir -p "$W1/sb1/subagents" "$W2" "$G1" "$RV" "$PR"

# task-a: one message streamed three times, one more, one after the close date.
brief "$W1/sa.jsonl" 2026-09-01T10:00:00Z "$H" task-a
for _ in 1 2 3; do asst "$W1/sa.jsonl" 2026-09-01T10:05:00Z msg_a1 claude-test 1000000 0 2000000 100000; done
asst "$W1/sa.jsonl" 2026-09-01T11:00:00Z msg_a2 claude-test 0 500000 0 0
asst "$W1/sa.jsonl" 2026-09-02T12:00:00Z msg_a3 claude-test 0 0 0 999
# The same slot reused by task-b, mentioning the review run; plus a subagent.
brief "$W1/sb1.jsonl" 2026-09-05T09:00:00Z "$H" task-b
asst "$W1/sb1.jsonl" 2026-09-05T09:05:00Z msg_b1 claude-test 10 20 30 40 "no-mistakes run $RUN started"
asst "$W1/sb1/subagents/agent-x.jsonl" 2026-09-05T09:06:00Z msg_b2 claude-test 0 0 0 5
# task-b relaunched in another slot.
brief "$W2/sb2.jsonl" 2026-09-06T09:00:00Z "$H" task-b
asst "$W2/sb2.jsonl" 2026-09-06T09:01:00Z msg_b3 claude-test 1 0 0 1
# A task-a brief that starts after task-a closed: no window, unattributed.
brief "$W2/late.jsonl" 2026-09-07T09:00:00Z "$H" task-a
asst "$W2/late.jsonl" 2026-09-07T09:01:00Z msg_late claude-test 5 5 5 5
# Another home's worker and a session with no brief: never attributed here.
brief "$W2/foreign.jsonl" 2026-09-05T09:00:00Z /elsewhere task-a
asst "$W2/foreign.jsonl" 2026-09-05T09:01:00Z msg_f claude-test 7 7 7 7
asst "$W2/plain.jsonl" 2026-09-05T09:01:00Z msg_p claude-test 9 9 9 9
# task-d quotes task-b's run later; the earlier mention keeps the review.
brief "$W2/sd.jsonl" 2026-09-08T09:00:00Z "$H" task-d
asst "$W2/sd.jsonl" 2026-09-08T09:01:00Z msg_d1 claude-test 2 0 0 2 "as run $RUN showed"
# Archived task-c.
brief "$G1/sc.jsonl" 2026-08-20T08:00:00Z "$H" task-c
asst "$G1/sc.jsonl" 2026-08-20T08:01:00Z msg_c1 claude-test 1 1 1 1
# no-mistakes review for the run task-b mentioned.
asst "$RV/review.jsonl" 2026-09-05T10:00:00Z msg_r1 claude-test 7 0 0 3
# Primary firstmate session.
asst "$PR/p.jsonl" 2026-09-05T10:00:00Z msg_p1 claude-test 100 0 0 1
asst "$PR/p.jsonl" 2026-09-05T10:00:01Z msg_p1 claude-test 100 0 0 1
asst "$PR/p.jsonl" 2026-09-06T10:00:00Z msg_p2 claude-test 50 0 0 0

# --- Codex session for task-b --------------------------------------------------
CXF="$CX/2026/09/06/rollout-2026-09-06T10-00-00-cx1.jsonl"
mkdir -p "$(dirname "$CXF")"
printf '{"timestamp":"2026-09-06T10:00:00Z","type":"session_meta","payload":{"id":"cx1","cwd":"/wt/widget-abc/3/widget"}}\n' > "$CXF"
printf '{"timestamp":"2026-09-06T10:00:01Z","type":"turn_context","payload":{"model":"gpt-test"}}\n' >> "$CXF"
printf '{"timestamp":"2026-09-06T10:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"FIRSTMATE_OP: v1 launch-brief: crewmate. echo x >> '"'"'%s/state/task-b.status'"'"'"}}\n' "$H" >> "$CXF"
codex_tok "$CXF" 2026-09-06T10:01:00Z 1000 1000 400 100 50
codex_tok "$CXF" 2026-09-06T10:01:01Z 1000 1000 400 100 50
codex_tok "$CXF" 2026-09-06T10:02:00Z 1200 200 0 0 10

run() { FM_HOME="$H" FM_COST_CLAUDE_PROJECTS="$CL" FM_COST_CODEX_SESSIONS="$CX" "$REPORT" "$@"; }
task() { jq -c --arg id "$2" '.tasks[] | select(.id == $id)' <<<"$1"; }

# --- tokens-only path ------------------------------------------------------------
OUT=$(run --json) || fail "report failed without a price table"
A=$(task "$OUT" task-a)
assert_equals '{"fresh_input":1000000,"cache_write":500000,"cache_read":2000000,"output":100000}' \
  "$(jq -c .tokens <<<"$A")" "task-a counts msg_a1 once despite three streamed copies and drops the post-close record"
assert_equals 1 "$(jq .dropped_after_close <<<"$A")" "task-a reports one record stamped after its window"
assert_equals "done 1 widget ship claude-test" "$(jq -r '"\(.outcome) \(.attempts) \(.repo) \(.kind) \(.model)"' <<<"$A")" "task-a identity"
assert_equals null "$(jq .cost_usd <<<"$A")" "no price table means no dollar figure"
pass "dedupe and time-window bound"

B=$(task "$OUT" task-b)
assert_equals '{"fresh_input":711,"cache_write":120,"cache_read":430,"output":106}' \
  "$(jq -c .tokens <<<"$B")" "task-b sums both Claude slots, its subagent, and the deduped Codex session"
assert_equals "in_flight 3 claude 10" "$(jq -r '"\(.outcome) \(.attempts) \(.harness) \(.review_tokens)"' <<<"$B")" \
  "task-b: three worker sessions, meta harness, review run folded in"
assert_equals "gpt-test+claude-test" "$(jq -r .model <<<"$B")" "task-b lists both models, heaviest first"
pass "attribution across a reused slot, relaunch attempts, and review"

C=$(task "$OUT" task-c)
assert_equals "done gadget scout 4" "$(jq -r '"\(.outcome) \(.repo) \(.kind) \(.tokens | add)"' <<<"$C")" "archived task-c"
assert_equals '[{"task":"task-a","source":"claude","session":"late"}]' "$(jq -c .unattributed <<<"$OUT")" \
  "a brief outside every task window is reported, not guessed"
assert_equals 4 "$(jq '.tasks | length' <<<"$OUT")" "the foreign-home and brief-less sessions claim no task"
assert_equals "0 []" "$(task "$OUT" task-d | jq -r .review_tokens) $(jq -c .ambiguous_review_runs <<<"$OUT")" \
  "a later quote of a run id neither steals nor blurs the review"
assert_equals null "$(jq .primary <<<"$OUT")" "primary block only on request"
pass "archive, unattributed, and foreign sessions"

TOON=$(run) || fail "TOON report failed"
assert_contains "$TOON" "tasks[4]{id,repo,kind,harness,model,outcome,attempts,elapsed_h,fresh_input,cache_write,cache_read,output,review_tokens,cost_usd}:" "TOON header"
assert_contains "$TOON" "  task-a,widget,ship,claude,claude-test,done,1," "TOON task-a row"
assert_contains "$TOON" "prices: absent, tokens only" "TOON names the absent price table"
pass "TOON output"

# --- filters ---------------------------------------------------------------------
assert_equals "task-a task-b task-d" "$(run --json --since 2026-09-01 | jq -r '[.tasks[].id] | sort | join(" ")')" "--since drops tasks closed before the date"
assert_equals "task-c" "$(run --json --repo gadget | jq -r '[.tasks[].id] | join(" ")')" "--repo"
assert_equals "task-a task-c" "$(run --json --task task-c --task task-a | jq -r '[.tasks[].id] | sort | join(" ")')" "--task repeatable"
P=$(run --json --primary | jq -c '[.primary[] | {day, fresh_input}]')
assert_equals '[{"day":"2026-09-05","fresh_input":100},{"day":"2026-09-06","fresh_input":50}]' "$P" "primary per-day totals, deduped"
pass "filters and primary block"

# --- priced path -----------------------------------------------------------------
printf '{"models":{"claude-test":{"fresh_input":3,"cache_write":4,"cache_read":0.5,"output":15}}}\n' > "$H/config/model-prices.json"
OUT=$(run --json) || fail "report failed with a price table"
assert_equals 7.5 "$(task "$OUT" task-a | jq .cost_usd)" "task-a priced per million tokens"
assert_equals null "$(task "$OUT" task-b | jq .cost_usd)" "a task with an unpriced model gets no partial dollar figure"
assert_equals '["gpt-test"]' "$(jq -c .unpriced <<<"$OUT")" "the unpriced model is named"
printf '{"models":{"claude-test":{"fresh_input":3,"cache_write":4,"cache_read":0.5,"output":15},"gpt-test":{"fresh_input":1,"cache_write":1,"cache_read":1,"output":1}}}\n' > "$H/config/model-prices.json"
assert_equals 0.0021 "$(run --json | jq '.tasks[] | select(.id == "task-b") | .cost_usd')" "task-b cost includes worker, Codex, and review tokens"
pass "priced path"

printf '{"models":{"claude-test":{"fresh_input":"cheap"}}}\n' > "$H/config/model-prices.json"
ERR=$(run 2>&1); rc=$?
expect_code 1 "$rc" "malformed price table"
assert_contains "$ERR" "malformed price table" "malformed price table is named"
rm "$H/config/model-prices.json"
pass "malformed price table"

# --- missing inputs ----------------------------------------------------------------
mkdir -p "$T/empty"
ERR=$(FM_HOME="$T/empty" FM_COST_CLAUDE_PROJECTS="$CL" FM_COST_CODEX_SESSIONS="$CX" "$REPORT" 2>&1); rc=$?
expect_code 1 "$rc" "missing backlog"
assert_contains "$ERR" "missing backlog: $T/empty/data/backlog.md" "missing backlog is named"
ERR=$(FM_HOME="$H" FM_COST_CLAUDE_PROJECTS="$T/none1" FM_COST_CODEX_SESSIONS="$T/none2" "$REPORT" 2>&1); rc=$?
expect_code 1 "$rc" "no transcript roots"
assert_contains "$ERR" "no transcripts" "absent transcript roots are named"
assert_contains "$(FM_HOME="$H" FM_COST_CLAUDE_PROJECTS="$CL" FM_COST_CODEX_SESSIONS="$T/none2" "$REPORT")" "codex=absent" \
  "one absent root is named on the sources line"
pass "missing inputs"
