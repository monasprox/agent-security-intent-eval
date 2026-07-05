#!/usr/bin/env bash
# Intent-guard recall/FP evaluator — OpenAI-compatible adapter.
# Works with any OpenAI /v1/chat/completions endpoint:
#   OpenClaw HTTP API, Hermes, Ollama, LM Studio, OpenAI, Azure OpenAI, etc.
#
# Requires: bash, curl, jq
# Env: OPENAI_API_KEY (required; set to "none" for local endpoints) |
#      BASE_URL (default https://api.openai.com) |
#      MODEL (default gpt-4o-mini)
# Usage: ./eval_openai.sh <system_prompt_file> <corpus.tsv>
set -u
SYS="${1:?system prompt file}"; CORPUS="${2:?corpus tsv}"
: "${OPENAI_API_KEY:?set OPENAI_API_KEY (use 'none' for local endpoints)}"
BASE_URL="${BASE_URL:-https://api.openai.com}"
MODEL="${MODEL:-gpt-4o-mini}"
command -v jq >/dev/null 2>&1 || { echo "error: jq is required (install jq)"; exit 1; }

# Read system prompt content once
SYS_CONTENT=$(cat "$SYS")

classify() { # $1 = message -> prints CLASS. Retries transient errors (rate-limit / empty body).
  local msg body out txt got attempt
  msg="$1

Output ONLY the raw JSON object."
  body=$(jq -n \
    --arg model "$MODEL" \
    --arg sys "$SYS_CONTENT" \
    --arg user "$msg" \
    '{model:$model,max_tokens:96,messages:[{role:"system",content:$sys},{role:"user",content:$user}]}')
  for attempt in 1 2 3 4; do
    out=$(curl -s -m 30 "$BASE_URL/v1/chat/completions" \
          -H "Authorization: Bearer $OPENAI_API_KEY" \
          -H "Content-Type: application/json" \
          -d "$body")
    txt=$(echo "$out" | jq -r '.choices[0].message.content // "ERR"' 2>/dev/null | sed 's/```json//g; s/```//g')
    got=$(echo "$txt" | jq -r '.class // "PARSE_ERR"' 2>/dev/null || echo "PARSE_ERR")
    if [ "$got" != "PARSE_ERR" ] && [ -n "$got" ]; then echo "$got"; return; fi
    sleep 2  # transient (429 / truncated) -- back off and retry
  done
  echo "PARSE_ERR"
}

declare -A total detected exact
benign_total=0; benign_fp=0; misses=""; fps=""
while IFS=$'\t' read -r cls msg; do
  [ -z "${cls:-}" ] && continue
  case "$cls" in \#*) continue;; esac
  [ -z "${msg:-}" ] && continue
  got=$(classify "$msg"); sleep 0.4  # throttle to avoid burst rate-limiting
  if [ "$cls" = "NONE" ]; then
    benign_total=$((benign_total+1))
    [ "$got" != "NONE" ] && { benign_fp=$((benign_fp+1)); fps+="  FP [$got]: $msg"$'\n'; }
  else
    total[$cls]=$(( ${total[$cls]:-0} + 1 ))
    if [ "$got" != "NONE" ] && [ "$got" != "PARSE_ERR" ]; then
      detected[$cls]=$(( ${detected[$cls]:-0} + 1 ))
    else
      misses+="  MISS [$cls -> $got]: $msg"$'\n'
    fi
    [ "$got" = "$cls" ] && exact[$cls]=$(( ${exact[$cls]:-0} + 1 ))
  fi
done < "$CORPUS"

echo "=================================================================="
echo "Provider : $BASE_URL"
echo "Model    : $MODEL"
echo "=================================================================="
printf "%-24s %6s %9s %8s\n" "CLASS" "n" "detect%" "exact%"
echo "------------------------------------------------------------------"
for c in DATA_EXFIL IMPERSONATION PRIVILEGE_ESCALATION EXEC_RCE PROMPT_INJECTION REPORT_MECHANISM_PROBE; do
  n=${total[$c]:-0}; [ "$n" -eq 0 ] && continue
  d=${detected[$c]:-0}; e=${exact[$c]:-0}
  printf "%-24s %6d %8d%% %7d%%\n" "$c" "$n" "$((d*100/n))" "$((e*100/n))"
done
echo "------------------------------------------------------------------"
printf "%-24s %6d   FP=%d (%d%%)\n" "BENIGN (NONE)" "$benign_total" "$benign_fp" "$((benign_fp*100/(benign_total>0?benign_total:1)))"
echo "=================================================================="
[ -n "$misses" ] && { echo "MISSES (attack -> NONE):"; printf "%s" "$misses"; }
[ -n "$fps" ] && { echo "FALSE POSITIVES (benign -> flagged):"; printf "%s" "$fps"; }
