#!/usr/bin/env bash
# Structural evidence and tokenless ownership-safe wait, with no live model.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-quota)
SCRIPT_DIR="$ROOT/bin"
FM_ROOT=$ROOT
CONFIG="$TMP_ROOT/config"
mkdir -p "$CONFIG"
FM_CLAUDE_QUOTA_TRANSCRIPT="$TMP_ROOT/session.jsonl"
# shellcheck source=bin/fm-claude-quota-lib.sh
. "$ROOT/bin/fm-claude-quota-lib.sh"
fixture() {
  node -e 'console.log(JSON.stringify({isApiErrorMessage:true,apiError:"usage_limit_reached",quotaLimits:{status:"rejected",rateLimitType:"five_hour",resetsAt:Number(process.argv[1])}}))' "$1" > "$FM_CLAUDE_QUOTA_TRANSCRIPT"
}
fixture "$(( $(date +%s) + 3600 ))"
if fm_claude_quota_reset; then fail 'absent opt-in must remain inert'; fi
: > "$CONFIG/claude-quota-pause"
fm_claude_quota_reset || fail 'future structured reset was ignored'
pass 'quota: future structural rejection pauses only with opt-in'
fixture "$(( $(date +%s) - 1 ))"
if fm_claude_quota_reset; then fail 'expired reset paused'; fi
for row in \
  '{"isApiErrorMessage":true,"apiError":"usage_limit_reached","message":"limit reached; resets tomorrow"}' \
  '{"isApiErrorMessage":true,"apiError":"overloaded_error","quotaLimits":{"status":"rejected","rateLimitType":"five_hour","resetsAt":4000000000}}' \
  '{"isApiErrorMessage":true,"apiError":"usage_limit_reached","quotaLimits":{"status":"allowed_warning","rateLimitType":"five_hour","resetsAt":4000000000}}' \
  '{"isApiErrorMessage":true,"apiError":"usage_limit_reached","quotaLimits":{"status":"rejected","rateLimitType":"seven_day","resetsAt":4000000000}}' \
  '{"isApiErrorMessage":false,"apiError":"usage_limit_reached","quotaLimits":{"status":"rejected","rateLimitType":"five_hour","resetsAt":4000000000}}'; do
  printf '%s\n' "$row" | jq -c --argjson reset "$(( $(date +%s) + 3600 ))" \
    'if .quotaLimits then .quotaLimits.resetsAt=$reset else . end' > "$FM_CLAUDE_QUOTA_TRANSCRIPT"
  if fm_claude_quota_reset; then fail "unrelated record paused: $row"; fi
done
fixture 4000000000
if fm_claude_quota_reset; then fail 'implausible reset paused'; fi
pass 'quota: expired, prose-only, warning, unrelated errors and implausible resets do not pause'
future=$(( $(date +%s) + 3600 ))
printf '{"isApiErrorMessage":true,"apiError":"usage_limit_reached","apiErrorParams":{"rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":%s}}}\n' "$future" > "$TMP_ROOT/explicit.jsonl"
printf '%s\n' "$TMP_ROOT/explicit.jsonl" > "$CONFIG/claude-quota-transcripts"
fm_claude_quota_reset || fail 'explicit path nested quota was ignored'
[ "$FM_CLAUDE_QUOTA_RESET" = "$future" ] || fail 'wrong explicit reset'
rm "$CONFIG/claude-quota-transcripts"
pass 'quota: explicit same-account transcript and nested API fields supported'
fixture "$(( $(date +%s) + 3600 ))"
node -e 'process.stdout.write("x".repeat(1024*1024+1)+"\n")' >> "$FM_CLAUDE_QUOTA_TRANSCRIPT"
if fm_claude_quota_reset; then fail 'read escaped the bounded transcript tail'; fi
pass 'quota: history outside bounded tail is never scanned'
# FIFO paths must never wedge the reader.
mkfifo "$TMP_ROOT/pipe"
printf '%s\n' "$TMP_ROOT/pipe" > "$CONFIG/claude-quota-transcripts"
if fm_claude_quota_reset; then fail 'FIFO was treated as evidence'; fi
rm "$CONFIG/claude-quota-transcripts"
fixture "$(( $(date +%s) + 2 ))"
quota_test_owner() { :; }
fm_claude_quota_wait quota_test_owner || fail 'owned wait failed'
[ "$FM_CLAUDE_QUOTA_WAITED" = 1 ] || fail 'wait did not park'
if fm_claude_quota_reset; then fail 'wait returned before reset'; fi
pass 'quota: tokenless wait resumes after the recorded reset'
fixture "$(( $(date +%s) + 3600 ))"
quota_lost_owner() { return 1; }
if fm_claude_quota_wait quota_lost_owner; then fail 'lost owner continued'; fi
pass 'quota: lost ownership cancels without changing evidence'

cp "$ROOT/tests/fixtures/claude-quota/rejected.jsonl" "$FM_CLAUDE_QUOTA_TRANSCRIPT"
if fm_claude_quota_reset; then fail 'recorded expired rejection paused'; fi
node -e 'const fs=require("fs"); const row=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); row.quotaLimits.resetsAt=Math.floor(Date.now()/1000)+30; row.apiErrorParams.rate_limit_info.resetsAt=row.quotaLimits.resetsAt; fs.writeFileSync(process.argv[2],JSON.stringify(row)+"\n");' \
  "$ROOT/tests/fixtures/claude-quota/rejected.jsonl" "$FM_CLAUDE_QUOTA_TRANSCRIPT"
fm_claude_quota_reset || fail 'recorded structural rejection with future reset ignored'
pass 'quota: sanitized real Claude rejection accepted; original expired reset ignored'
# A new helper process sees a host's proven reset after the source disappears,
# but a new main-session identity must never inherit that cached knowledge.
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
printf '%s\n' "$$" > "$STATE/.lock"
printf 'main-one\n' > "$STATE/.lock-session"
fixture "$(( $(date +%s) + 3600 ))"
fm_claude_quota_reset || fail 'could not record proven shared reset'
: > "$FM_CLAUDE_QUOTA_TRANSCRIPT"
fm_claude_quota_reset || fail 'host death lost proven reset'
printf 'main-two\n' > "$STATE/.lock-session"
if fm_claude_quota_reset; then fail 'different main session inherited cached reset'; fi
pass 'quota: durable reset survives source loss and remains bound to primary session'
