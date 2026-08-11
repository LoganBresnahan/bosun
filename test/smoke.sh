#!/bin/sh
# bosun smoke tests — the behavioral contract, exercised against a REAL kernel.
# Run on every CI OS. POSIX sh; no bashisms.
#
#   1. group      : bosun makes the child a process-group leader (pgid == pid),
#                   and kill(-pid) takes a REPARENTED GRANDCHILD that a
#                   tree-walk cannot see. This is the capability that is
#                   silently absent on stock macOS today (no setsid(1) there).
#   2. pdeathsig  : (Linux only) SIGKILL the parent -> the kernel reaps the
#                   child with no reaper process involved.
#   3. exit codes : 127 command-not-found, 125 flag errors, exec passthrough.
#   4. no-setsid  : opt-out leaves the child in the caller's group.
#
# Usage: test/smoke.sh [path-to-bosun]   (default: zig-out/bin/bosun)

set -u
BOSUN="${1:-zig-out/bin/bosun}"
FAILS=0
OS="$(uname -s)"

say()  { printf '%s\n' "$*"; }
pass() { say "  ok    - $*"; }
fail() { say "  FAIL  - $*"; FAILS=$((FAILS + 1)); }

[ -x "$BOSUN" ] || { say "bosun not found at $BOSUN"; exit 2; }

# ── 1. group leadership + reparented-grandchild kill ─────────────────────────
"$BOSUN" -- sh -c 'sleep 30 & sleep 30' &
LEADER=$!
sleep 1
PGID=$(ps -o pgid= -p "$LEADER" | tr -d ' ')
if [ "$PGID" = "$LEADER" ]; then
    pass "group: pgid == pid ($LEADER)"
else
    fail "group: pgid=$PGID != pid=$LEADER"
fi

MEMBERS_BEFORE=$(ps -eo pgid= | tr -d ' ' | grep -c "^${LEADER}\$")
[ "$MEMBERS_BEFORE" -ge 2 ] \
    && pass "group: $MEMBERS_BEFORE members before kill (leader + grandchild)" \
    || fail "group: expected >=2 members, saw $MEMBERS_BEFORE"

env kill -TERM -- "-$LEADER" 2>/dev/null   # env: dash's BUILTIN kill rejects `-- -pid`
sleep 1
MEMBERS_AFTER=$(ps -eo pgid= | tr -d ' ' | grep -c "^${LEADER}\$")
if [ "$MEMBERS_AFTER" -eq 0 ]; then
    pass "group: kill(-pgid) emptied the group, grandchild included"
else
    fail "group: $MEMBERS_AFTER member(s) survived the group kill"
    env kill -KILL -- "-$LEADER" 2>/dev/null
fi
wait "$LEADER" 2>/dev/null

# ── 2. pdeathsig: SIGKILL the parent, kernel reaps the child ────────────────
if [ "$OS" = "Linux" ]; then
    # A disposable parent that spawns via bosun then blocks forever.
    sh -c '
        '"$BOSUN"' --pdeathsig KILL --parent $$ -- sleep 300 &
        echo "$!" > /tmp/bosun-smoke-child.$$
        mv /tmp/bosun-smoke-child.$$ /tmp/bosun-smoke-child
        exec sleep 300
    ' &
    PARENT=$!
    sleep 1
    CHILD=$(cat /tmp/bosun-smoke-child 2>/dev/null); rm -f /tmp/bosun-smoke-child
    if [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
        kill -KILL "$PARENT" 2>/dev/null   # unclean death: no chance to clean up
        wait "$PARENT" 2>/dev/null
        sleep 1
        if kill -0 "$CHILD" 2>/dev/null; then
            fail "pdeathsig: child $CHILD survived its parent's SIGKILL"
            kill -KILL "$CHILD" 2>/dev/null
        else
            pass "pdeathsig: kernel reaped child on parent SIGKILL (no reaper needed)"
        fi
    else
        fail "pdeathsig: setup — child never appeared"
        kill -KILL "$PARENT" 2>/dev/null
    fi

    # The race guard: a --parent that is ALREADY wrong dies immediately.
    # Probe by STATE + wait STATUS, not kill -0: a self-signaled racer is a
    # ZOMBIE until this shell reaps it, and kill -0 counts zombies as alive
    # (the exact sharp edge the README documents — and it bit this very test
    # under busybox ash in the alpine CI job). wait cannot be lied to, and
    # additionally proves the death was SIGKILL (rc 137 = 128+9).
    "$BOSUN" --pdeathsig KILL --parent 1 -- sleep 300 &
    RACER=$!
    sleep 1
    RSTAT=$(ps -o stat= -p "$RACER" 2>/dev/null | tr -d ' ')
    case "$RSTAT" in
        ""|Z*)
            wait "$RACER" 2>/dev/null
            RC=$?
            [ "$RC" -eq 137 ] \
                && pass "pdeathsig: --parent mismatch self-signals with KILL (wait rc=137)" \
                || fail "pdeathsig: racer died with rc=$RC, want 137"
            ;;
        *)
            fail "pdeathsig: --parent mismatch did not self-signal (stat=$RSTAT)"
            kill -KILL "$RACER" 2>/dev/null
            ;;
    esac
else
    # macOS: the HARD flag must refuse loudly; the SOFT flag must degrade.
    "$BOSUN" --pdeathsig KILL -- true 2>/dev/null
    [ $? -eq 125 ] \
        && pass "pdeathsig: hard flag refuses loudly on $OS (exit 125)" \
        || fail "pdeathsig: hard flag should exit 125 on $OS"
    "$BOSUN" --pdeathsig-soft KILL -- true \
        && pass "pdeathsig: soft flag degrades explicitly on $OS" \
        || fail "pdeathsig: soft flag should succeed on $OS"
fi

# ── 3. exit-code contract ────────────────────────────────────────────────────
"$BOSUN" -- definitely-not-a-command-xyz 2>/dev/null
[ $? -eq 127 ] && pass "exit: 127 for command-not-found" || fail "exit: want 127"

"$BOSUN" --bogus-flag -- true 2>/dev/null
[ $? -eq 125 ] && pass "exit: 125 for unknown flag" || fail "exit: want 125"

"$BOSUN" -- sh -c 'exit 42'
[ $? -eq 42 ] && pass "exit: child status passes through (42)" || fail "exit: want 42"

# ── 4. --no-setsid opt-out ───────────────────────────────────────────────────
"$BOSUN" --no-setsid -- sleep 5 &
NS=$!
sleep 1
NS_PGID=$(ps -o pgid= -p "$NS" | tr -d ' ')
if [ "$NS_PGID" != "$NS" ]; then
    pass "--no-setsid: child stays in caller's group"
else
    fail "--no-setsid: child unexpectedly leads its own group"
fi
kill "$NS" 2>/dev/null; wait "$NS" 2>/dev/null

say ""
if [ "$FAILS" -eq 0 ]; then say "smoke: all green"; exit 0
else say "smoke: $FAILS failure(s)"; exit 1; fi
