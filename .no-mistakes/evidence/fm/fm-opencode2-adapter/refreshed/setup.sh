#!/usr/bin/env bash
set -u
ROOT=$PWD
E=/home/dscott/.no-mistakes/evidence/01M54WH36WR8NGK9EHZG3DDNGF/refreshed
D="$ROOT/.oc2-refreshed"
mkdir -p "$D"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$D/lab"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
export TMUX_TMPDIR
TMUX_TMPDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$FM_HOME")
cleanup() {
 tmux -L fm-lab kill-server 2>/dev/null || true
 "$ROOT/bin/fm-lab-home.sh" teardown "$FM_HOME"
 rm -rf "$D"
}

mkdir -p "$D/project" "$FM_HOME/data/oc2-recheck"
git -C "$D/project" init -q
git -C "$D/project" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial
git -C "$D/project" worktree add -qb fm/oc2-recheck "$D/worker"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'off\n' > "$FM_HOME/config/supervision-host"
cat > "$FM_HOME/data/oc2-recheck/brief.md" <<'BRIEF'
# Task
## Captain's intent
Reply with exactly PLATFORM_OK. Do not use tools or change files.

## Firstmate spec
This is a disposable live validation. Reply once and wait.
BRIEF
tmux -L fm-lab new-session -d -s primary -n fm-oc2-recheck -x 110 -y 34 -c "$D/worker"
export TMUX
TMUX="$(tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')"
cat > "$FM_HOME/state/oc2-recheck.meta" <<META
window=primary:fm-oc2-recheck
worktree=$D/worker
project=$D/project
harness=opencode2
kind=ship
mode=local-only
yolo=off
branch=fm/oc2-recheck
model=zai/glm-5.3-flash
effort=default
backend=tmux
META
"$ROOT/bin/fm-spawn.sh" oc2-recheck --relaunch > "$E/launch.txt" 2>&1
cat "$E/launch.txt"
