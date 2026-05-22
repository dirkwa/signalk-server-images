#!/usr/bin/env bash
# Commit a single state file and push, with rebase+retry to survive races
# against other build-*.yml workflows pushing concurrently.
#
# Usage: commit-state.sh <state-file> <new-content> <commit-message>

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <state-file> <new-content> <commit-message>" >&2
  exit 2
fi

STATE_FILE="$1"
NEW_CONTENT="$2"
MSG="$3"

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

attempt=1
while [ "$attempt" -le 5 ]; do
  echo "$NEW_CONTENT" > "$STATE_FILE"

  if git diff --quiet -- "$STATE_FILE"; then
    echo "State file unchanged after rebase; nothing to commit."
    exit 0
  fi

  git add "$STATE_FILE"
  # Amend-able single-purpose commit; we rewrite on each retry after rebase.
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    git commit -m "$MSG"
  else
    git commit -m "$MSG"
  fi

  if git push origin HEAD 2>&1; then
    echo "Pushed state update on attempt $attempt."
    exit 0
  fi

  echo "Push rejected on attempt $attempt; rebasing and retrying..."
  git fetch origin
  # Reset our local commit, then rebase, then re-apply the state change next loop.
  git reset --hard HEAD~1
  git rebase origin/"$(git rev-parse --abbrev-ref HEAD)"
  attempt=$((attempt + 1))
  sleep $((attempt * 2))
done

echo "Failed to push state update after $((attempt - 1)) attempts" >&2
exit 1
