#!/usr/bin/env bash
# Supported runtime selection for the supervision host's real TS dispatcher.
# No engine or harness is launched; a durable check row proves positive routing.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$ROOT/bin/fm-supervision-engine-lib.sh"

LAB=$(fm_test_tmproot fm-supervision-node)
REAL_NODE=$(command -v node)
DISPATCH="$ROOT/bin/fm-branch-dispatch.mjs"
mkdir -p "$LAB/home/config" "$LAB/home/state" "$LAB/old" "$LAB/supported" "$LAB/pin"
CONFIG="$LAB/home/config"

node_wrapper() {  # <path> <version>
  cat > "$1" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '%s\\n' '$2'; exit 0; fi
printf '%s\\n' "\$*" >> '$1.calls'
exec "$REAL_NODE" "\$@"
EOF
  chmod +x "$1"
}
node_wrapper "$LAB/old/node" v22.15.0
node_wrapper "$LAB/supported/node" v24.11.0
node_wrapper "$LAB/pin/node" v26.12.0

append_wake "$LAB/home/state" check merge 'check: merge landed: fixture'

# An installed supported runtime must replace an obsolete inherited PATH entry.
# The real dispatcher imports its TS owner and must accept a real eligible row.
out=$(printf 'check: merge landed: fixture\n' | FM_HOME="$LAB/home" PATH="$LAB/old:$PATH" \
  fm_supervision_node "$CONFIG" "$DISPATCH" offer --afk) || fail 'old PATH prevented a real branch offer'
assert_contains "$out" 'eligible=1' 'supported fallback did not offer the queued check to the away branch'
assert_contains "$out" 'corrupted=0' 'runtime selection concealed a corrupt wake fixture'
assert_contains "$out" 'rows=1' 'the real offer did not preserve its exact claimable row'
out=$(FM_HOME="$LAB/home" PATH="$LAB/old:$PATH" fm_supervision_node "$CONFIG" "$DISPATCH" scope --afk) || fail 'old PATH prevented a real scope scan'
assert_contains "$out" 'status=safe' 'the real scope scan was not safe'
assert_contains "$out" 'rows=1' 'the scope scan lost the pending row'
assert_absent "$LAB/old/node.calls" 'the unsupported PATH runtime executed supervision dispatch'
pass 'supervision node: an old inherited PATH still computes a real eligible offer and scope with a supported runtime'

PATH="$LAB/supported:$PATH" fm_supervision_node_resolve "$CONFIG" || fail 'supported PATH runtime was refused'
assert_equals "$LAB/supported/node" "$FM_SUPERVISION_NODE" 'supported PATH did not take precedence over fallback installations'
printf '%s\n' "$LAB/pin/node" > "$CONFIG/supervision-node"
PATH="$LAB/supported:$PATH" fm_supervision_node_resolve "$CONFIG" || fail 'valid explicit runtime pin was refused'
assert_equals "$LAB/pin/node" "$FM_SUPERVISION_NODE" 'explicit runtime pin did not take precedence over PATH'
pass 'supervision node: supported PATH wins over fallback discovery, and an explicit pin wins over PATH'

for pin in "$LAB/old/node" "$LAB/absent-node" relative-node; do
  printf '%s\n' "$pin" > "$CONFIG/supervision-node"
  if fm_supervision_node_resolve "$CONFIG"; then fail "invalid explicit runtime pin was silently replaced: $pin"; fi
  assert_contains "$FM_SUPERVISION_NODE_PROBLEM" "$pin" 'invalid pin diagnostic omitted its exact path'
  [ -z "$FM_SUPERVISION_NODE" ] || fail 'an invalid explicit runtime pin retained a previously selected binary'
done
printf '%s\n' "$LAB/old/node" > "$CONFIG/supervision-node"
fm_supervision_node_resolve "$CONFIG" && fail 'unsupported explicit runtime was accepted'
assert_contains "$FM_SUPERVISION_NODE_PROBLEM" '22.15.0' 'unsupported runtime diagnostic omitted its version'
node_wrapper "$LAB/pin/node" v24.10.9
printf '%s\n' "$LAB/pin/node" > "$CONFIG/supervision-node"
fm_supervision_node_resolve "$CONFIG" && fail 'runtime below the 24.11 floor was accepted'
assert_contains "$FM_SUPERVISION_NODE_PROBLEM" '24.10.9' 'version-floor diagnostic omitted the installed version'
printf '%s\n%s\n' "$LAB/pin/node" "$REAL_NODE" > "$CONFIG/supervision-node"
fm_supervision_node_resolve "$CONFIG" && fail 'multiple explicit runtime pins were accepted'
pass 'supervision node: malformed, missing and unsupported explicit pins fail with concrete diagnostics'

# An executable named node can hang during readiness. The explicit pin remains
# authoritative, so a timeout must refuse instead of silently selecting PATH.
mkdir "$LAB/hanging"
cat > "$LAB/hanging/node" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" > '$LAB/hanging/pid'
exec sleep 10
EOF
chmod +x "$LAB/hanging/node"
printf '%s\n' "$LAB/hanging/node" > "$CONFIG/supervision-node"
started=$SECONDS
if PATH="$LAB/supported:$PATH" fm_supervision_node_resolve "$CONFIG"; then
  fail 'a hanging explicit runtime pin was silently replaced'
fi
elapsed=$((SECONDS - started))
[ "$elapsed" -lt 8 ] || fail "runtime readiness exceeded its bounded probe ($elapsed seconds)"
assert_contains "$FM_SUPERVISION_NODE_PROBLEM" "$LAB/hanging/node" 'timeout diagnostic omitted the explicit runtime path'
assert_contains "$FM_SUPERVISION_NODE_PROBLEM" '3s' 'timeout diagnostic omitted the probe bound'
[ -z "$FM_SUPERVISION_NODE" ] || fail 'a timed-out explicit pin selected another runtime'
child=$(cat "$LAB/hanging/pid")
if kill -0 "$child" 2>/dev/null; then fail 'timed-out runtime child survived readiness'; fi
pass 'supervision node: a hanging explicit runtime pin is bounded, reaped and never silently replaced'
