#!/usr/bin/env bash
# fm-project-capacity-lib.sh - how many workers a project admits at once on this
# machine, and whether a fresh worker spawn still fits.
#
# A project can depend on a machine-local resource that only a few workers can
# use at the same time: a heavy test suite, a local editor stack, a device.
# Firstmate cannot see which part of a worker's life touches that resource, so
# the captain declares how many workers the project admits on this machine, and
# bin/fm-spawn.sh defers a fresh worker beyond that number instead of launching
# it only to spend full-context turns retrying the resource. A deferred task
# keeps its queued backlog item and is dispatched again when a place frees.
# Without a declaration nothing changes and dispatch stays uncapped
# (AGENTS.md section 7).
#
# This file is the single owner of the declaration format, of what holds a
# place, and of the admission verdict. docs/configuration.md "Project capacity"
# is the operator reference, and bin/fm-spawn.sh owns where the check runs.
#
# Declaration: config/project-capacity in the local root Firstmate home (the home
# bin/fm-wake-lib.sh's fm_firstmate_root_home resolves), so every home on this
# machine reads the same number for the same machine's resources. One line per
# project:
#   <project-name> <capacity>
# <project-name> is the project's registered name, which is the basename of its
# clone directory, and <capacity> is a positive integer of at most six digits.
# The capacity is the last whitespace-separated field, so the name before it may
# contain spaces. Blank lines are ignored. A line is a comment when it is `#`,
# when `#` is followed by whitespace, or when it starts with `#` and its last
# field is not an integer. A project whose name begins with `#` is declared by
# writing that `#` immediately against the rest of the name and ending the line
# with the capacity, for example `#repo 2`. A name that is `#`, or that begins
# with `#` followed by a space, is the same spelling as a comment and cannot be
# declared. Any other shape, a project named twice, or an unreadable file makes
# the whole declaration unreadable, and bin/fm-spawn.sh then refuses every fresh
# ship or scout spawn from this machine's homes rather than guessing which limit
# was meant.
#
# Optional temporary limit: config/project-capacity-burst in the same directory
# has '<project-name> <capacity> <expiry-epoch>' lines. Names and comments follow
# the capacity file, and capacity has the same positive six-digit constraint.
# Expiry is a positive Unix epoch in seconds of at most twelve digits. Any
# duplicate or malformed declaration refuses fresh spawns. Lookup validates
# every entry, and applies a matching burst only when the project has a base
# declaration and current time is strictly before expiry. Expiry simply returns
# future admissions to the base limit; it never interrupts existing workers.
#
# Occupancy: a place is held by every task record, in any local Firstmate home on
# this machine (fm_local_firstmate_state_dirs in bin/fm-wake-lib.sh), that
#   - is not a secondmate, which is a persistent home rather than a worker,
#   - names the same project identity, meaning its project resolves to the same
#     shared project lock path (fm_treehouse_project_lock_path), which is keyed
#     by the project's resolved origin, so workers in any clone of that origin
#     are counted, and
#   - has no recorded PR handoff: the pr= line bin/fm-pr-check.sh records when a
#     worker's PR is ready, after which the worker waits on review or merge and
#     no longer uses local resources.
# In the default records mode, a place therefore frees when a PR-based ship records its ready PR, or when any
# task is cleaned up and its record removed. A local-only ship and a scout have
# no recorded handoff and hold their place until cleanup. A worker that is
# steered back into work after its PR handoff is not counted again.
# The declaration is matched by the spawning clone's directory name, so clones
# of one origin share the cap only when they use that same directory name. A
# clone of that origin under a different directory name finds no declaration
# and is not capped, though its workers still count as holders for a
# same-origin clone that is capped.
# A record whose project directory no longer exists cannot be matched and holds
# no place. Remote homes are never walked, because their workers run on another
# machine.
#
# Optional accounting: config/project-capacity-mode in that same config directory
# has one '<project-name> <records|agents>' line per project, with the same name,
# whitespace, and comment rules (the final field is a mode instead of a number).
# Absent entries use records, preserving the occupancy contract above. Duplicate,
# malformed, or unreadable mode declarations refuse fresh spawns too.
# In agents mode PR handoff does not free a place: every matching task counts
# unless the validated endpoint is positively agent-free or a running Herdr
# session returns structured proof that its recorded pane is gone.
# An existing per-task spawn or metadata lock reserves the place through launch
# delivery. Missing tmux endpoints still count because the metadata does not prove
# the socket identity; ambiguous, unreadable, unverified, and malformed endpoints
# also count. Status events and semantic idle are not release evidence.
# This is a conservative live-agent admission limit, not a resource or job limit:
# an idle but running agent still counts, background pipelines are not inspected,
# and steering/relaunching an existing task does not reacquire admission, so later
# resumptions can exceed the limit. No record, endpoint, or worktree is removed.
#
# Race safety: bin/fm-spawn.sh evaluates admission while holding the shared
# project lock and keeps holding it until the new task record is published, so
# two concurrent spawns for one project can never both publish from the same
# count. A spawn on an uncapped project can still publish a holder for a capped
# same-origin clone, so every backend takes that lock whenever the declaration
# caps any project; Orca, which otherwise never takes it, is included. Freeing a
# place needs no lock, because removing a record or adding pr= only ever lowers
# the count.
#
# Requires bin/fm-wake-lib.sh (root home, local homes, project lock path),
# bin/fm-secondmate-registry-lib.sh (which the local-homes walk reads), and
# bin/fm-backend.sh (fm_meta_get) to be sourced first. No side effects on source.

# Exit status of a spawn deferred because the project is at capacity: the
# sysexits "temporary failure" code, so a caller can tell a deferral that leaves
# the task queued from an ordinary failure.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_PROJECT_CAPACITY_DEFER_EXIT=75

# The config directory holding this machine's declaration: the spawning home's
# own <config-dir> when that home is the local root (so an override of it
# applies), otherwise the root home's config/.
fm_project_capacity_config_dir() {  # <spawning-home> <spawning-config-dir>
  local home=$1 config=$2 root home_real
  root=$(fm_firstmate_root_home "$home") || return 1
  home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  if [ "$root" = "$home_real" ]; then
    printf '%s\n' "$config"
  else
    printf '%s/config\n' "$root"
  fi
}

# Read the declared capacity for one project.
# Sets FM_PROJECT_CAPACITY_FILE to the declaration path, FM_PROJECT_CAPACITY
# to the project's capacity, or to empty when the project declares none, and
# FM_PROJECT_CAPACITY_ANY to 1 when the declaration caps any project at all.
# FM_PROJECT_CAPACITY_BASE keeps the ordinary limit and
# FM_PROJECT_CAPACITY_BURST_EXPIRES exposes a matching burst's expiry, even when
# expired. FM_PROJECT_CAPACITY_MODE is records or agents.
# Returns 1 with FM_PROJECT_CAPACITY_ERROR when the declaration is unreadable.
fm_project_capacity_lookup() {  # <config-dir> <project-name>
  local name=$2 line lineno=0 pname pcap seen='|'
  FM_PROJECT_CAPACITY_FILE="$1/project-capacity"
  FM_PROJECT_CAPACITY=
  FM_PROJECT_CAPACITY_ANY=
  FM_PROJECT_CAPACITY_BASE=
  FM_PROJECT_CAPACITY_BURST_EXPIRES=
  FM_PROJECT_CAPACITY_ERROR=
  fm_project_capacity_mode_lookup "$1" "$name" || return 1
  if [ ! -e "$FM_PROJECT_CAPACITY_FILE" ] && [ ! -L "$FM_PROJECT_CAPACITY_FILE" ]; then
    fm_project_capacity_burst_lookup "$1" "$name"
    return $?
  fi
  if [ ! -f "$FM_PROJECT_CAPACITY_FILE" ] || [ ! -r "$FM_PROJECT_CAPACITY_FILE" ]; then
    FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    # '#' followed by whitespace is always a comment, including one that ends
    # with a number. A line that begins with '#' glued to the rest of a name is
    # a declaration only when its last field is an integer; any other such line
    # stays a comment, so a note does not refuse every spawn.
    case "$line" in
      '' | '#' | '#'[[:space:]]*) continue ;;
      '#'*)
        case "${line##*[[:space:]]}" in
          *[!0-9]*) continue ;;
        esac
        ;;
    esac
    # The capacity is the last field, so the name before it may hold spaces.
    pcap=${line##*[[:space:]]}
    pname=${line%"$pcap"}
    pname=${pname%"${pname##*[![:space:]]}"}
    if [ -z "$pname" ]; then
      FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno is not '<project-name> <capacity>'"
      FM_PROJECT_CAPACITY=
      return 1
    fi
    case "$pcap" in
      '' | *[!0-9]* | 0*)
        FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno gives $pname a capacity that is not a positive integer"
        FM_PROJECT_CAPACITY=
        return 1
        ;;
    esac
    if [ "${#pcap}" -gt 6 ]; then
      FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno gives $pname a capacity longer than six digits"
      FM_PROJECT_CAPACITY=
      return 1
    fi
    case "$seen" in
      *"|$pname|"*)
        FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno names $pname a second time"
        FM_PROJECT_CAPACITY=
        return 1
        ;;
    esac
    seen="$seen$pname|"
    [ "$pname" != "$name" ] || FM_PROJECT_CAPACITY=$pcap
  done < "$FM_PROJECT_CAPACITY_FILE"
  [ "$seen" = '|' ] || FM_PROJECT_CAPACITY_ANY=1
  FM_PROJECT_CAPACITY_BASE=$FM_PROJECT_CAPACITY
  fm_project_capacity_burst_lookup "$1" "$name"
}

# Apply a validated, unexpired temporary limit only over a declared base limit.
# Current time is read once per lookup; there is no timer or running-job action.
fm_project_capacity_burst_lookup() {  # <config-dir> <project-name>
  local file="$1/project-capacity-burst" name=$2 line expiry limit project rest seen='|' lineno=0 now
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then return 0; fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_PROJECT_CAPACITY_ERROR="$file is not a readable regular file"
    return 1
  fi
  now=$(date +%s) || { FM_PROJECT_CAPACITY_ERROR="current time cannot be read for $file"; return 1; }
  case "$now" in ''|*[!0-9]*) FM_PROJECT_CAPACITY_ERROR="current time cannot be read for $file"; return 1 ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      '' | '#' | '#'[[:space:]]*) continue ;;
      '#'*) case "${line##*[[:space:]]}" in *[!0-9]*) continue ;; esac ;;
    esac
    expiry=${line##*[[:space:]]}
    rest=${line%"$expiry"}
    rest=${rest%"${rest##*[![:space:]]}"}
    limit=${rest##*[[:space:]]}
    project=${rest%"$limit"}
    project=${project%"${project##*[![:space:]]}"}
    case "$limit" in
      ''|*[!0-9]*|0*) FM_PROJECT_CAPACITY_ERROR="$file line $lineno has an invalid burst limit"; return 1 ;;
    esac
    case "$expiry" in
      ''|*[!0-9]*|0*) FM_PROJECT_CAPACITY_ERROR="$file line $lineno has an invalid expiry epoch"; return 1 ;;
    esac
    if [ -z "$project" ] || [ "${#limit}" -gt 6 ] || [ "${#expiry}" -gt 12 ]; then
      FM_PROJECT_CAPACITY_ERROR="$file line $lineno is not '<project-name> <capacity> <expiry-epoch>' with bounded positive numbers"
      return 1
    fi
    case "$seen" in
      *"|$project|"*) FM_PROJECT_CAPACITY_ERROR="$file line $lineno names $project a second time"; return 1 ;;
    esac
    seen="$seen$project|"
    if [ "$project" = "$name" ]; then
      FM_PROJECT_CAPACITY_BURST_EXPIRES=$expiry
      if [ -n "$FM_PROJECT_CAPACITY_BASE" ] && [ "$now" -lt "$expiry" ]; then
        FM_PROJECT_CAPACITY=$limit
        FM_PROJECT_CAPACITY_FILE=$file
      fi
    fi
  done < "$file"
}

# Read the optional per-project accounting mode, defaulting to records.
# Like capacity, invalid entries anywhere refuse the whole declaration.
fm_project_capacity_mode_lookup() {  # <config-dir> <project-name>
  local file="$1/project-capacity-mode" name=$2 line mode project seen='|' lineno=0
  FM_PROJECT_CAPACITY_MODE=records
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then return 0; fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_PROJECT_CAPACITY_ERROR="$file is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      '' | '#' | '#'[[:space:]]*) continue ;;
      '#'*)
        case "${line##*[[:space:]]}" in agents|records) ;; *) continue ;; esac
        ;;
    esac
    mode=${line##*[[:space:]]}
    project=${line%"$mode"}
    project=${project%"${project##*[![:space:]]}"}
    case "$mode" in
      agents|records) ;;
      *) FM_PROJECT_CAPACITY_ERROR="$file line $lineno has an unknown accounting mode"; return 1 ;;
    esac
    if [ -z "$project" ]; then
      FM_PROJECT_CAPACITY_ERROR="$file line $lineno is not '<project-name> <records|agents>'"
      return 1
    fi
    case "$seen" in
      *"|$project|"*) FM_PROJECT_CAPACITY_ERROR="$file line $lineno names $project a second time"; return 1 ;;
    esac
    seen="$seen$project|"
    [ "$project" != "$name" ] || FM_PROJECT_CAPACITY_MODE=$mode
  done < "$file"
}

# A conservative release proof, delegated to the existing backend classifier.
# Locks reserve provisional records until launch delivery has completed; even
# an abandoned lock remains occupied rather than risking a concurrent launch.
fm_project_capacity_agent_released() {  # <meta> <id> <state>
  local meta=$1 id=$2 state=$3 lock verdict backend target
  lock=$(fm_meta_lock_path "$meta") || return 1
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || return 1
  lock="$state/.spawn-$id.lock"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || return 1
  fm_backend_validate_task_endpoint "$meta" "$id" endpoint-only >/dev/null 2>&1 || return 1
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  fm_backend_source "$backend" || return 1
  verdict=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || return 1
  case "$backend:$verdict" in
    *:dead) return 0 ;;
    herdr:missing)
      fm_backend_herdr_parse_target "$target" || return 1
      [ "$(fm_backend_herdr_server_running_state "$FM_BACKEND_HERDR_SESSION")" = running ] || return 1
      [ "$(fm_backend_herdr_pane_presence_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" = dead ]
      ;;
    *) return 1 ;;
  esac
}

# Count the task records holding a place in one project's capacity.
# <project-lock> is fm_treehouse_project_lock_path for the project being
# admitted, and <project-dir> is that project's own directory, which matches
# without recomputing its identity. The local homes come from
# fm_local_firstmate_state_dirs <first-state>. <own-id> is the task being
# admitted; its own record in <first-state> is the one this spawn replaces, so
# it is not counted.
# Sets FM_PROJECT_CAPACITY_OCCUPANTS to the count and
# FM_PROJECT_CAPACITY_OCCUPANT_IDS to a comma-separated list of the holders,
# each outside <first-state> qualified with its home. Returns 1 with
# FM_PROJECT_CAPACITY_ERROR when the local homes cannot be enumerated, or when
# a state directory or task record in them cannot be read, since skipping it
# could undercount the holders.
fm_project_capacity_occupants() {  # <project-lock> <project-dir> <first-state> <own-id>
  local want=$1 own=$2 first=$3 self=$4 state meta kind project lock id label i
  local -a cache_dirs cache_locks
  FM_PROJECT_CAPACITY_OCCUPANTS=0
  FM_PROJECT_CAPACITY_OCCUPANT_IDS=
  FM_PROJECT_CAPACITY_ERROR=
  fm_local_firstmate_state_dirs "$first" || {
    FM_PROJECT_CAPACITY_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  cache_dirs=("$own")
  cache_locks=("$want")
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -e "$state" ] && { [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; }; then
      FM_PROJECT_CAPACITY_ERROR="local Firstmate state directory $state cannot be read"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$meta" != "$first/$self.meta" ] || continue
      [ -r "$meta" ] || {
        FM_PROJECT_CAPACITY_ERROR="task record $meta cannot be read"
        return 1
      }
      kind=$(fm_meta_get "$meta" kind)
      [ "$kind" != secondmate ] || continue
      if [ "${FM_PROJECT_CAPACITY_MODE:-records}" = records ]; then
        [ -z "$(fm_meta_get "$meta" pr)" ] || continue
      fi
      project=$(fm_meta_get "$meta" project)
      [ -n "$project" ] || continue
      lock=
      i=0
      while [ "$i" -lt "${#cache_dirs[@]}" ]; do
        if [ "${cache_dirs[$i]}" = "$project" ]; then
          lock=${cache_locks[$i]}
          break
        fi
        i=$((i + 1))
      done
      if [ "$i" -ge "${#cache_dirs[@]}" ]; then
        lock=$(fm_treehouse_project_lock_path "$project" 2>/dev/null) || lock=
        cache_dirs+=("$project")
        cache_locks+=("$lock")
      fi
      [ -n "$lock" ] && [ "$lock" = "$want" ] || continue
      id=$(basename "$meta" .meta)
      if [ "${FM_PROJECT_CAPACITY_MODE:-records}" = agents ] &&
        fm_project_capacity_agent_released "$meta" "$id" "$state"; then
        continue
      fi
      label=$id
      [ "$state" = "$first" ] || label="$id in $(dirname "$state")"
      FM_PROJECT_CAPACITY_OCCUPANTS=$((FM_PROJECT_CAPACITY_OCCUPANTS + 1))
      FM_PROJECT_CAPACITY_OCCUPANT_IDS="${FM_PROJECT_CAPACITY_OCCUPANT_IDS:+$FM_PROJECT_CAPACITY_OCCUPANT_IDS, }$label"
    done
  done
  return 0
}
