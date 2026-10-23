#!/usr/bin/env bash
# Opt-in quota pause, shared by Claude Stop and the supervision host.
# CONFIG/claude-quota-pause enables it. CONFIG/claude-quota-transcripts may
# name up to 32 absolute JSONL paths (one per line) from the same account.
# The Stop payload path and this host's explicit engine session are also read.
# fm-claude-quota.mjs owns the bounded structural evidence predicate.
# No account identity is exposed by these records; this scope is an operator
# assertion, not account detection. Missing/unreadable evidence cannot pause.
# state/.claude-quota-reset shares proven evidence across host death, keyed by
# the existing main-session identity; a later session never inherits it.
# A pause changes no queue row, grant, lease, generation or session ownership.
# Waiters recheck their caller's ownership/cancellation predicate each second;
# callers retain their existing traps. The reset is held in memory while
# waiting, so multi-hour waits do not repeatedly read transcript contents.

# shellcheck disable=SC2153 # CONFIG is the calling script's resolved config directory.
fm_claude_quota_reset() {  # sets FM_CLAUDE_QUOTA_RESET; success means paused
  local key=
  FM_CLAUDE_QUOTA_RESET=
  [ -f "$CONFIG/claude-quota-pause" ] || return 1
  if [ -n "${STATE:-}" ]; then
    if ! command -v fm_supervision_host_main_key >/dev/null 2>&1; then
      # shellcheck source=bin/fm-wake-lib.sh
      . "$SCRIPT_DIR/fm-wake-lib.sh"
      # shellcheck source=bin/fm-supervision-engine-lib.sh
      . "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
    fi
    key=$(fm_supervision_host_main_key "$STATE" 2>/dev/null) || key=
  fi
  FM_CLAUDE_QUOTA_RESET=$(node "$SCRIPT_DIR/fm-claude-quota.mjs" "$CONFIG" \
    "${FM_CLAUDE_QUOTA_TRANSCRIPT:-}" "${ENGINE_SESSION:-}" "$FM_ROOT" "${STATE:-}" "$key" 2>/dev/null) || return 1
  case "$FM_CLAUDE_QUOTA_RESET" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

# shellcheck disable=SC2034 # FM_CLAUDE_QUOTA_WAITED is an output for callers.
fm_claude_quota_wait() {  # <ownership/cancellation predicate>; 1 means stand down
  local owner=$1 deadline
  FM_CLAUDE_QUOTA_WAITED=0
  while fm_claude_quota_reset; do
    FM_CLAUDE_QUOTA_WAITED=1
    deadline=$((SECONDS + FM_CLAUDE_QUOTA_RESET - $(date +%s)))
    while [ "$SECONDS" -lt "$deadline" ] && [ -f "$CONFIG/claude-quota-pause" ]; do
      "$owner" || return 1
      sleep 1
    done
    "$owner" || return 1
  done
  return 0
}
