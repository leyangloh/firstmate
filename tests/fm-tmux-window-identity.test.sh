#!/usr/bin/env bash
# tests/fm-tmux-window-identity.test.sh - portable regression for tmux task
# window identity (docs/tmux-backend.md "Window identity").
#
# A spawned window is pinned against automatic and escape-sequence renames, but
# an explicit `tmux rename-window` from outside firstmate still renames it, and
# every name-based read then fails. It runs REAL tmux on a private socket (`-L`)
# and proves, through the shared resolver and the fm-peek.sh executable, that a
# recorded window id still finds the window and re-pins its name, that legacy
# name-only records keep working, and that a gone window reads absent rather than
# matching another window - including tmux's own silent display-message fallback.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-window-identity-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-window-identity.XXXXXX")
SESSION=identity
HOME_DIR="$LAB/home"
STATE="$HOME_DIR/state"

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# A `tmux` shim on PATH so every bare `tmux` call, including the ones inside
# fm-peek.sh, reaches the private socket and never touches the host's sessions.
mkdir -p "$LAB/shim" "$LAB/wt" "$STATE"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

t() { "$REAL_TMUX" -L "$SOCKET" "$@"; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

t new-session -d -s "$SESSION" -n home -c "$LAB/wt" || fail "could not start the private tmux server"

window_name_of() {  # <window-id>
  t list-windows -a -F '#{window_id} #{window_name}' | awk -v id="$1" '$1 == id { $1 = ""; sub(/^ /, ""); print; exit }'
}

write_meta() {  # <id> [<window-id> <server-start>]
  {
    echo "window=$SESSION:fm-$1"
    echo "endpoint_task_id=$1"
    echo "worktree=$LAB/wt"
    echo "project=$LAB/wt"
    echo "harness=claude"
    echo "kind=ship"
    [ -z "${2:-}" ] || echo "tmux_window_id=$2"
    [ -z "${3:-}" ] || echo "tmux_server_start=$3"
  } > "$STATE/$1.meta"
}

# --- spawn primitives: pinned window plus a recorded stable identity ---------
WID=$(fm_backend_tmux_create_task "$SESSION" fm-t1 "$LAB/wt") || fail "create_task failed"
case "$WID" in @[0-9]*) ;; *) fail "create_task printed '$WID', not a window id" ;; esac
STARTED=$(fm_backend_tmux_server_start)
case "$STARTED" in ''|*[!0-9]*) fail "server start '$STARTED' is not an epoch" ;; esac
[ "$(t show-window-options -v -t "$WID" automatic-rename)" = off ] || fail "automatic-rename not pinned off at creation"
[ "$(t show-window-options -v -t "$WID" allow-rename)" = off ] || fail "allow-rename not pinned off at creation"
pass "create_task pins the window and yields a window id plus server start"
write_meta t1 "$WID" "$STARTED"
t send-keys -t "$WID" 'echo IDENTITY-MARKER-T1' Enter
sleep 0.5

# --- an explicit rename drifts the name; the id still finds and re-pins it ---
t rename-window -t "$WID" '! drifted'
[ "$(window_name_of "$WID")" = '! drifted' ] || fail "setup: explicit rename did not drift the pinned window"
# Divergence assertion: the recorded name is now unresolvable by name alone.
fm_backend_tmux_window_member "$SESSION" fm-t1 && fail "setup: drifted name still resolvable, case is vacuous"
got=$(fm_backend_target_of_meta "$STATE/t1.meta")
[ "$got" = "$SESSION:fm-t1" ] || fail "resolver printed '$got' for a drifted window, want $SESSION:fm-t1"
[ "$(window_name_of "$WID")" = fm-t1 ] || fail "resolver did not re-pin the drifted name"
pass "resolver finds a renamed window by id and re-pins its recorded name"

t rename-window -t "$WID" '✓ drifted again'
out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-peek.sh" t1 20 2>&1) \
  || fail "fm-peek.sh failed on a drifted window: $out"
case "$out" in *IDENTITY-MARKER-T1*) ;; *) fail "fm-peek.sh captured the wrong pane: $out" ;; esac
[ "$(window_name_of "$WID")" = fm-t1 ] || fail "fm-peek.sh path did not re-pin the drifted name"
pass "fm-peek.sh reads a drifted window through its recorded id"

t rename-window -t "$WID" 'drift for teardown'
fm_backend_validate_task_endpoint "$STATE/t1.meta" t1 || fail "endpoint validation refused a drifted id-bound record"
[ "$FM_BACKEND_VALIDATED_TARGET" = "$SESSION:fm-t1" ] \
  || fail "validated target '$FM_BACKEND_VALIDATED_TARGET', want $SESSION:fm-t1"
fm_backend_target_exists tmux "$FM_BACKEND_VALIDATED_TARGET" || fail "validated target does not exist"
pass "endpoint validation (teardown and control) resolves a drifted window by id"

# --- legacy record with only a name keeps working ----------------------------
WID2=$(fm_backend_tmux_create_task "$SESSION" fm-t2 "$LAB/wt") || fail "create_task t2 failed"
write_meta t2
[ "$(fm_backend_target_of_meta "$STATE/t2.meta")" = "$SESSION:fm-t2" ] || fail "legacy record did not resolve by name"
fm_backend_target_exists tmux "$SESSION:fm-t2" || fail "legacy named window reads absent"
# A `.pane` suffix rides a window INDEX, not a window name: a name may itself
# contain a dot, so bin/fm-backend.sh's fm_backend_target_exists header limits
# the split to indexes.
WID2_INDEX=$(t list-windows -a -F '#{window_id} #{window_index}' | awk -v id="$WID2" '$1 == id { print $2; exit }')
[ -n "$WID2_INDEX" ] || fail "could not read the live window's index"
fm_backend_target_exists tmux "$SESSION:$WID2_INDEX.0" || fail "pane-qualified index target of a live window reads absent"
fm_backend_target_exists tmux "$SESSION:$WID2" || fail "window-id target of a live window reads absent"
fm_backend_target_exists tmux "$SESSION:no-such-window.0" && fail "pane-qualified target of an absent window reads present"
pass "a name-only legacy record resolves by name, and explicit id and pane targets still read present"

# --- conflict: the recorded name is held by another window -------------------
t rename-window -t "$WID" drifted
t rename-window -t "$WID2" fm-t1
got=$(fm_backend_target_of_meta "$STATE/t1.meta")
[ "$got" = "$SESSION:$WID" ] || fail "resolver printed '$got' while another window holds the name, want $SESSION:$WID"
[ "$(window_name_of "$WID2")" = fm-t1 ] || fail "resolver renamed the window holding the name"
fm_backend_target_exists tmux "$got" || fail "id target reads absent while the window is live"
[ "$(fm_backend_tmux_agent_state "$got")" != missing ] || fail "agent state reads missing for a live id target"
pass "a name held by another window resolves to the task's own window id"
t rename-window -t "$WID2" fm-t2

# --- gone window reads absent, never another window --------------------------
t kill-window -t "$WID"
# Divergence assertion: tmux's own display-message answers an absent window
# from the session's current window with status 0.
t display-message -p -t "$SESSION:fm-t1" '#{pane_id}' >/dev/null 2>&1 \
  || fail "setup: display-message no longer falls back on this tmux, case is vacuous"
got=$(fm_backend_target_of_meta "$STATE/t1.meta")
[ "$got" = "$SESSION:fm-t1" ] || fail "gone window with a free name resolved to '$got'"
fm_backend_target_exists tmux "$got" && fail "gone window reads present"
[ "$(fm_backend_tmux_agent_state "$got")" = missing ] || fail "gone window agent state is not missing"
pass "a gone window reads absent despite tmux's display-message fallback"

STRANGER=$(t new-window -dP -F '#{window_id}' -t "$SESSION:" -n fm-t1)
got=$(fm_backend_target_of_meta "$STATE/t1.meta")
[ "$got" = "$SESSION:$WID" ] || fail "gone window whose name a stranger reused resolved to '$got'"
fm_backend_target_exists tmux "$got" && fail "gone window matched the stranger holding its name"
[ "$(fm_backend_tmux_agent_state "$got")" = missing ] || fail "gone window agent state is not missing with a stranger holding its name"
[ "$(window_name_of "$STRANGER")" = fm-t1 ] || fail "resolver touched the stranger window"
pass "a gone window never matches a stranger that reused its name"
t kill-window -t "$STRANGER"

# --- a different server lifetime never trusts a reused id --------------------
OTHER=$(t new-window -dP -F '#{window_id}' -t "$SESSION:" -n unrelated)
write_meta t3 "$OTHER" 1
got=$(fm_backend_target_of_meta "$STATE/t3.meta")
[ "$got" = "$SESSION:fm-t3" ] || fail "id from another server lifetime resolved to '$got'"
[ "$(window_name_of "$OTHER")" = unrelated ] || fail "resolver renamed a window whose id came from another server lifetime"
fm_backend_target_exists tmux "$got" && fail "id from another server lifetime reads present"
pass "an id recorded under another server lifetime is not trusted"

exit 0
