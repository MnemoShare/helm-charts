#!/usr/bin/env bash
# Resolve the review verdict from whatever durable artifact exists.
#
# WHY THIS EXISTS: the gate used to depend solely on the review bot choosing to
# write /tmp/claude-verdict.txt. When it doesn't, the run is indistinguishable
# from a genuine BLOCK — the PR is blocked with no finding to act on and
# nothing posted to the PR UI. Observed on helm-charts#37: is_error=false,
# permission_denials_count=0, num_turns=4, 11s, $0.03 — the bot ran cleanly and
# produced no file, no review, and no VERDICT line. Two reruns behaved
# identically. A model-chosen side effect is not a control-flow primitive.
#
# Precedence (most to least direct):
#   1. /tmp/claude-verdict.txt        — what the bot was asked to write
#   2. VERDICT: line in the action's own execution log
#   3. VERDICT: line in a review the bot posted on this HEAD SHA
#
# Writes the normalized verdict to /tmp/claude-verdict.txt and sets
# has_verdict=true|false on $GITHUB_OUTPUT. Never fails the job: deciding what
# a missing verdict MEANS is the enforce step's business, not this script's.
set -uo pipefail

VERDICT_FILE=/tmp/claude-verdict.txt

emit() {
  # COMMENT is advisory — it must not gate the merge.
  local v="$1"
  case "$v" in
    COMMENT*) v="APPROVE" ;;
  esac
  printf '%s\n' "$v" > "$VERDICT_FILE"
  echo "has_verdict=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "::notice::Verdict resolved via $2: $v"
  exit 0
}

if [ -s "$VERDICT_FILE" ]; then
  emit "$(head -n1 "$VERDICT_FILE" | sed 's/[[:space:]]*$//')" "the bot's verdict file"
fi

# (2) the action's execution log
for f in "${EXECUTION_FILE:-}" "${RUNNER_TEMP:-/tmp}/claude-execution-output.json"; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  line=$(grep -oE 'VERDICT:[[:space:]]*(APPROVE|BLOCK|COMMENT)[^"\\]*' "$f" | tail -n1 || true)
  if [ -n "$line" ]; then
    emit "$(printf '%s' "$line" | sed -E 's/^VERDICT:[[:space:]]*//')" "the action's execution log"
  fi
done

# (3) a review the bot posted on this HEAD SHA
if [ -n "${PR_NUMBER:-}" ] && [ -n "${REPO:-}" ]; then
  head_sha=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)
  if [ -n "$head_sha" ]; then
    body=$(gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" \
      --jq "[.[] | select(.commit_id == \"$head_sha\")] | last | .body // empty" 2>/dev/null || true)
    line=$(printf '%s' "$body" | grep -oE 'VERDICT:[[:space:]]*(APPROVE|BLOCK|COMMENT).*' | tail -n1 || true)
    if [ -n "$line" ]; then
      emit "$(printf '%s' "$line" | sed -E 's/^VERDICT:[[:space:]]*//')" "the bot's PR review"
    fi
  fi
fi

echo "has_verdict=false" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "::warning::No verdict from any channel (file, execution log, PR review)."
