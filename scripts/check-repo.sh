#!/usr/bin/env bash
# Fails when the repo tracks material that does not belong in a code repo:
# article drafts, reviews, research notes, experiment logs, diagram sources,
# article-writing skills, or a filled-in .env. Run from anywhere in the repo.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
pattern='(^|/)(drafts|reviews|research|experiments|articles?)/|\.drawio$|(^|/)\.claude/skills/[^/]*(article|content|writing)[^/]*/|(^|/)\.env$|(^|/)\.claude/backlog-runs/'
found=$(git ls-files | grep -E "$pattern" || true)
if [ -n "$found" ]; then
  echo "check-repo: these files do not belong in this repo:" >&2
  echo "$found" >&2
  exit 1
fi
echo "check-repo: ok"
