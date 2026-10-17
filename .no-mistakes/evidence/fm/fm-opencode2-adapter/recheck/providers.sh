#!/usr/bin/env bash
set -u
ROOT=$PWD
E=/home/dscott/.no-mistakes/evidence/01M54WH36WR8NGK9EHZG3DDNGF/recheck
D="$ROOT/.oc2-providers"
mkdir -p "$D/config"
trap 'rm -rf "$D"' EXIT
. "$ROOT/bin/fm-opencode2-lib.sh"
bin=$(fm_opencode2_resolve_binary)
{ command -v opencode; opencode --version; printf 'selected=%s\n' "$bin"; "$bin" --version; } > "$E/binary.txt"
providers=$(fm_opencode2_platform_providers "$bin" https://ai.simplifying.cloud)
readarray -t ps <<< "$providers"
policy=$(fm_opencode2_policies_json "${ps[@]}")
export OPENCODE_CONFIG_DIR="$D/config" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_CONFIG_CONTENT="{\"permission\":{\"*\":\"allow\"}$policy}"
cd "$D"
timeout 30 "$bin" models --standalone > "$E/models.txt" 2>&1
for model in openai/gpt-5.5 minimax-coding-plan/MiniMax-M3 zai-coding-plan/glm-5.3 ollama/deepseek-coder-v2:16b; do
 printf 'model=%s\n' "$model"
 timeout 20 "$bin" run --standalone --model "$model" 'Reply OK.'
 printf 'exit=%s\n' "$?"
done > "$E/personal-refusals.txt" 2>&1
timeout 20 "$bin" models --standalone --print-logs 2>&1 | python3 -c 'import sys,re
for line in sys.stdin:
 if "401" in line or ("ai.simplifying.cloud" in line and "config" in line):
  print(re.sub(r"(?i)(token|authorization|apiKey)([=: ]+)[^ ,}]+",r"\1\2[REDACTED]",line),end="")' > "$E/auth-diagnostic.txt"
