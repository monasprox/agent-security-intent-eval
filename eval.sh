#!/usr/bin/env bash
# Intent-guard recall/FP evaluator. Runs a TSV corpus (EXPECTED_CLASS<TAB>message)
# through an Anthropic-compatible classifier and reports per-class recall (detected =
# non-NONE) + exact-class accuracy + benign false-positive rate.
#
# Requires: bash, curl, jq
# Env: ANTHROPIC_API_KEY (required) | BASE_URL (default https://api.anthropic.com) |
#      MODEL (default claude-haiku-4-5)
# Usage: ./eval.sh <system_prompt_file> <corpus.tsv>
set -u
SYS="${1:?system prompt file}"; CORPUS="${2:?corpus tsv}"
: "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY}"
BASE_URL="${BASE_URL:-https://api.anthropic.com}"
MODEL="${MODEL:-claude-haiku-4-5}"
command -v jq >/dev/null 2>&1 || { echo "error: jq is required (install jq)"; exit 1; }

classify() { # $1 = message -> prints CLASS. Retries transient errors (rate-limit / empty body).
  local msg body out txt got attempt
  msg="[Message]
$1

Output ONLY the raw JSON object."
  body=$(jq -n --rawfile s "$SYS" --arg m "$msg" --arg model "$MODEL" \
    '{model:$model,max_tokens:96,system:$s,messages:[{role:"user",content:$m}]}')
  for attempt in 1 2 3 4; do
    out=$(curl -s -m 30 "$BASE_URL/v1/messages" \
          -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
          -H "content-type: application/json" -d "$body")
    txt=$(echo "$out" | jq -r '.content[0].text // "ERR"' 2>/dev/null | sed 's/```json//g; s/```//g')
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
