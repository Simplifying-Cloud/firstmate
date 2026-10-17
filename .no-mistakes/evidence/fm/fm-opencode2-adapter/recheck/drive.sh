#!/usr/bin/env bash
set -u
ROOT=$PWD
E=/home/dscott/.no-mistakes/evidence/01M54WH36WR8NGK9EHZG3DDNGF/recheck
D="$ROOT/.oc2-recheck"
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
trap cleanup EXIT
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
"$ROOT/bin/fm-spawn.sh" unsupported "$D/project" --secondmate --harness opencode2 > "$E/secondmate.txt" 2>&1
printf 'exit=%s\n' "$?" >> "$E/secondmate.txt"
"$ROOT/bin/fm-spawn.sh" oc2-recheck --relaunch --harness opencode2 --model openai/gpt-5.5 > "$E/forbidden.txt" 2>&1
printf 'exit=%s\n' "$?" >> "$E/forbidden.txt"
"$ROOT/bin/fm-spawn.sh" oc2-recheck --relaunch > "$E/launch.txt" 2>&1
rc=$?; printf 'exit=%s\n' "$rc" >> "$E/launch.txt"
[ "$rc" = 0 ] || exit "$rc"
sleep 20
tmux -L fm-lab capture-pane -p -t primary > "$E/tui.txt"
cat "$FM_HOME/state/oc2-recheck.busy-state" > "$E/busy-before.txt"
"$ROOT/bin/fm-control.sh" oc2-recheck interrupt > "$E/interrupt.txt" 2>&1
printf 'exit=%s\n' "$?" >> "$E/interrupt.txt"
sleep 2
cat "$FM_HOME/state/oc2-recheck.busy-state" > "$E/after-interrupt.txt"
[ ! -f "$FM_HOME/state/oc2-recheck.turn-ended" ] || printf 'turn-ended notification exists\n' >> "$E/after-interrupt.txt"
cat "$FM_HOME/state/oc2-recheck.busy-gen" > "$E/generation-before.txt"
touch "$FM_HOME/state/oc2-recheck.opencode-config/old-sentinel"
"$ROOT/bin/fm-control.sh" oc2-recheck relaunch --note 'Repeat the one-word response; live validation only.' > "$E/relaunch.txt" 2>&1
printf 'exit=%s\n' "$?" >> "$E/relaunch.txt"
sleep 15
cat "$FM_HOME/state/oc2-recheck.busy-gen" > "$E/generation-after.txt"
[ ! -d "$FM_HOME/state/oc2-recheck.opencode-config" ] || printf 'replacement config directory exists\n' >> "$E/relaunch.txt"
[ -e "$FM_HOME/state/oc2-recheck.opencode-config/old-sentinel" ] || printf 'old sentinel removed\n' >> "$E/relaunch.txt"
tmux -L fm-lab capture-pane -p -t primary > "$E/tui-relaunched.txt"
"$ROOT/bin/fm-control.sh" oc2-recheck exit > "$E/exit.txt" 2>&1
printf 'exit=%s\n' "$?" >> "$E/exit.txt"
. "$ROOT/bin/fm-opencode2-lib.sh"
bin=$(fm_opencode2_resolve_binary)
providers=$(fm_opencode2_platform_providers "$bin" https://ai.simplifying.cloud)
readarray -t ps <<< "$providers"
policy=$(fm_opencode2_policies_json "${ps[@]}")
printf '{"permission":{"*":"allow"}%s}\n' "$policy" > "$E/policy.json"
cd "$D/worker"
OPENCODE_CONFIG_DIR="$FM_HOME/state/oc2-recheck.opencode-config" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_CONFIG_CONTENT="$(cat "$E/policy.json")" timeout 45 "$bin" run --standalone --model zai/glm-5.3-flash 'Reply exactly PLATFORM_OK; do not use tools.' > "$E/platform-turn.txt" 2>&1
printf 'exit=%s\n' "$?" >> "$E/platform-turn.txt"
