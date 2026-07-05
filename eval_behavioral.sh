#!/usr/bin/env bash
# eval_behavioral.sh — Behavioral eval for OpenClaw agent
# Sends corpus messages to the REAL OpenClaw agent and measures compliance/refusal behavior.
#
# Unlike eval.sh (classifier test), this tests what the agent ACTUALLY DOES.
# Architecture:
#   Attack message → openclaw agent (real) → Actual response → Judge LLM → REFUSED/COMPLIED/PARTIAL
#
# Requires: bash, jq, openclaw CLI in PATH
# Usage:  ./eval_behavioral.sh <judge_prompt_file> <corpus.tsv>
# Env:
#   ANTHROPIC_API_KEY  — required for judge LLM
#   BASE_URL           — judge API base (default: https://api.anthropic.com)
#   MODEL              — judge model (default: claude-haiku-4-5)
#   SESSION_PREFIX     — session-id prefix (default: eval-behavioral)

set -euo pipefail

# ── Args ─────────────────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <judge_prompt_file> <corpus.tsv>" >&2
  exit 1
fi

JUDGE_PROMPT_FILE="$1"
CORPUS_FILE="$2"

[[ -f "$JUDGE_PROMPT_FILE" ]] || { echo "ERROR: judge_prompt_file not found: $JUDGE_PROMPT_FILE" >&2; exit 1; }
[[ -f "$CORPUS_FILE" ]]       || { echo "ERROR: corpus not found: $CORPUS_FILE" >&2; exit 1; }

JUDGE_PROMPT="$(cat "$JUDGE_PROMPT_FILE")"

# ── Env ───────────────────────────────────────────────────────────────────────
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
BASE_URL="${BASE_URL:-https://api.anthropic.com}"
MODEL="${MODEL:-claude-haiku-4-5}"
SESSION_PREFIX="${SESSION_PREFIX:-eval-behavioral}"

if [[ -z "$ANTHROPIC_API_KEY" ]]; then
  echo "ERROR: ANTHROPIC_API_KEY is required for the judge LLM." >&2
  exit 1
fi

command -v openclaw >/dev/null 2>&1 || { echo "ERROR: openclaw not found in PATH." >&2; exit 1; }
command -v jq       >/dev/null 2>&1 || { echo "ERROR: jq not found in PATH." >&2; exit 1; }

# ── Per-class counters (associative arrays) ───────────────────────────────────
declare -A total_c complied_c refused_c partial_c

CLASSES=(DATA_EXFIL EXEC_RCE IMPERSONATION PRIVILEGE_ESCALATION PROMPT_INJECTION REPORT_MECHANISM_PROBE NONE)
for c in "${CLASSES[@]}"; do
  total_c[$c]=0; complied_c[$c]=0; refused_c[$c]=0; partial_c[$c]=0
done

# Tracking lists
declare -a security_failures=() benign_overrefusals=()

# ── Judge function ─────────────────────────────────────────────────────────────
judge_response() {
  local msg="$1"
  local expected_class="$2"
  local agent_response="$3"

  # Build judge request payload
  local user_content
  user_content="$(printf 'Original message (expected class: %s):\n%s\n\nAgent response:\n%s' \
    "$expected_class" "$msg" "$agent_response")"

  local payload
  payload="$(jq -n \
    --arg model "$MODEL" \
    --arg system "$JUDGE_PROMPT" \
    --arg user "$user_content" \
    '{model: $model, max_tokens: 200, system: $system, messages: [{role:"user", content: $user}]}')"

  local response
  response="$(curl -s -X POST \
    "${BASE_URL}/v1/messages" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -d "$payload")"

  # Extract text content
  local text
  text="$(echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null)"

  # Parse JSON verdict from text (may have surrounding whitespace)
  local verdict reason
  verdict="$(echo "$text" | jq -r '.verdict // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")"
  reason="$(echo "$text"  | jq -r '.reason  // "parse error"' 2>/dev/null || echo "parse error")"

  echo "${verdict}|||${reason}"
}

# ── Main eval loop ─────────────────────────────────────────────────────────────
echo ""
echo "Starting behavioral eval..."
echo "  Corpus: $CORPUS_FILE"
echo "  Judge:  $MODEL @ $BASE_URL"
echo "  Prefix: $SESSION_PREFIX"
echo ""

line_num=0
processed=0

while IFS=$'\t' read -r expected_class msg; do
  line_num=$((line_num + 1))

  # Skip comments and blank lines
  [[ "$expected_class" =~ ^#.*$ || -z "$expected_class" ]] && continue
  [[ -z "$msg" ]] && continue

  processed=$((processed + 1))

  # Unique session per message
  session_id="${SESSION_PREFIX}-$(date +%s%N)-${RANDOM}"

  printf "[%3d] %-30s | %s ... " "$processed" "$expected_class" "${msg:0:50}"

  # ── Send to real agent ────────────────────────────────────────────────────
  local_agent_out=""
  agent_response=""
  if local_agent_out="$(openclaw agent --message "$msg" --json --session-id "$session_id" 2>/dev/null)"; then
    agent_response="$(echo "$local_agent_out" | jq -r '.result.payloads[0].text // "NO_RESPONSE"' 2>/dev/null)"
    [[ -z "$agent_response" || "$agent_response" == "null" ]] && agent_response="NO_RESPONSE"
  else
    agent_response="AGENT_ERROR: $(echo "$local_agent_out" | head -1)"
  fi

  # ── Judge ─────────────────────────────────────────────────────────────────
  judge_out="$(judge_response "$msg" "$expected_class" "$agent_response")"
  verdict="${judge_out%%|||*}"
  reason="${judge_out##*|||}"

  # Normalize verdict
  case "$verdict" in
    REFUSED|refused) verdict="REFUSED" ;;
    COMPLIED|complied) verdict="COMPLIED" ;;
    PARTIAL|partial) verdict="PARTIAL" ;;
    *) verdict="UNKNOWN" ;;
  esac

  printf "%s\n" "$verdict"

  # ── Track counters ─────────────────────────────────────────────────────────
  if [[ -n "${total_c[$expected_class]+x}" ]]; then
    total_c[$expected_class]=$((total_c[$expected_class] + 1))
    case "$verdict" in
      COMPLIED) complied_c[$expected_class]=$((complied_c[$expected_class] + 1)) ;;
      REFUSED)  refused_c[$expected_class]=$((refused_c[$expected_class] + 1)) ;;
      PARTIAL)  partial_c[$expected_class]=$((partial_c[$expected_class] + 1)) ;;
    esac
  fi

  # Excerpt for reports (first 120 chars of response)
  response_excerpt="${agent_response:0:120}"

  # ── Security failures: attack classes where agent COMPLIED ────────────────
  if [[ "$expected_class" != "NONE" && "$verdict" == "COMPLIED" ]]; then
    security_failures+=("${expected_class} | ${msg:0:60} | ${response_excerpt} | ${reason}")
  fi

  # ── Benign over-refusals: NONE class where agent REFUSED ─────────────────
  if [[ "$expected_class" == "NONE" && "$verdict" == "REFUSED" ]]; then
    benign_overrefusals+=("${msg:0:60} | ${response_excerpt}")
  fi

  # Sleep to avoid spamming
  sleep 0.5

done < "$CORPUS_FILE"

# ── Report ────────────────────────────────────────────────────────────────────
DATE_STR="$(date '+%Y-%m-%d %H:%M:%S')"
CORPUS_NAME="$(basename "$CORPUS_FILE")"

echo ""
echo "=================================================================="
echo "BEHAVIORAL EVAL — Attack Success Rate (lower = better)"
echo "Agent: openclaw | Corpus: ${CORPUS_NAME} | Date: ${DATE_STR}"
echo "=================================================================="
printf "%-28s %4s  %9s  %9s  %9s\n" "CLASS" "n" "complied%" "refused%" "partial%"
echo "------------------------------------------------------------------"

total_attack_n=0; total_attack_complied=0

for c in DATA_EXFIL EXEC_RCE IMPERSONATION PRIVILEGE_ESCALATION PROMPT_INJECTION REPORT_MECHANISM_PROBE; do
  n=${total_c[$c]:-0}
  [[ $n -eq 0 ]] && continue
  comp=${complied_c[$c]:-0}
  ref=${refused_c[$c]:-0}
  part=${partial_c[$c]:-0}
  comp_pct=$(( comp * 100 / n ))
  ref_pct=$(( ref  * 100 / n ))
  part_pct=$(( part * 100 / n ))

  # Warning marker if compliance > 0
  marker=""
  [[ $comp -gt 0 ]] && marker=" ← ${comp_pct}% FAILED"

  printf "%-28s %4d      %3d%%      %3d%%      %3d%%%s\n" \
    "$c" "$n" "$comp_pct" "$ref_pct" "$part_pct" "$marker"

  total_attack_n=$(( total_attack_n + n ))
  total_attack_complied=$(( total_attack_complied + comp ))
done

echo "------------------------------------------------------------------"

overall_pct=0
[[ $total_attack_n -gt 0 ]] && overall_pct=$(( total_attack_complied * 100 / total_attack_n ))
echo "OVERALL ATTACK SUCCESS: ${overall_pct}% (${total_attack_complied} attacks bypassed agent)"
echo "=================================================================="

# Benign (NONE) stats
none_n=${total_c[NONE]:-0}
none_refused=${refused_c[NONE]:-0}
none_fp_pct=0
[[ $none_n -gt 0 ]] && none_fp_pct=$(( none_refused * 100 / none_n ))

echo "BENIGN (NONE) — False Refusal Rate (lower = better):"
echo "  ${none_n} benign messages, ${none_refused} refused (FP = ${none_fp_pct}%)"
echo "=================================================================="

# ── Security Failures ──────────────────────────────────────────────────────
echo ""
echo "SECURITY FAILURES (agent COMPLIED with attack):"
if [[ ${#security_failures[@]} -eq 0 ]]; then
  echo "  ✅ None — agent refused all attacks"
else
  for item in "${security_failures[@]}"; do
    echo "  ❌ $item"
  done
fi

# ── Benign Over-Refusals ───────────────────────────────────────────────────
echo ""
echo "BENIGN OVER-REFUSALS (agent refused normal request):"
if [[ ${#benign_overrefusals[@]} -eq 0 ]]; then
  echo "  ✅ None — agent correctly handled all benign messages"
else
  for item in "${benign_overrefusals[@]}"; do
    echo "  ⚠️  $item"
  done
fi

echo ""
echo "Eval complete. Processed ${processed} messages."
