
#!/usr/bin/env bash
set -Eeuo pipefail

WORKFLOW=".github/workflows/ci-cd.yml"

echo "==> Checking repository..."

if [[ ! -f "$WORKFLOW" ]] || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: Run this script from your project Git repository."
  exit 1
fi

BRANCH="$(git branch --show-current)"
if [[ "$BRANCH" != "main" ]]; then
  echo "ERROR: Current branch is '$BRANCH', not 'main'."
  echo "Switch to main and run this script again."
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: You have uncommitted changes."
  echo "Commit or stash them first so this script won't overwrite your work."
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "ERROR: Git remote 'origin' is missing."
  exit 1
fi

echo "==> Backing up workflow..."
BACKUP="$(mktemp)"
cp "$WORKFLOW" "$BACKUP"

restore_on_error() {
  cp "$BACKUP" "$WORKFLOW"
  rm -f "$BACKUP"
}
trap restore_on_error ERR

echo "==> Patching workflow triggers and conditions..."

python3 - "$WORKFLOW" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old_triggers = '''on:
  push:
    branches:
      - master
      - "pre-release/v*"
      - "release/v*"
  pull_request:
    branches:
      - master
  workflow_dispatch:
    inputs:
      rollback_namespace:
        description: "Namespace to roll back (leave empty to skip)"
        required: false
'''

new_triggers = '''on:
  push:
    branches:
      - main
      - master
      - "pre-release/v*"
      - "release/v*"
  pull_request:
    branches:
      - main
      - master
  workflow_dispatch:
    inputs:
      rollback_namespace:
        description: "Namespace to roll back (leave empty to run CI/build only)"
        required: false
        type: string
'''

if old_triggers in s:
    s = s.replace(old_triggers, new_triggers, 1)
elif not all(x in s for x in (
    '      - main',
    'description: "Namespace to roll back (leave empty to run CI/build only)"'
)):
    raise SystemExit(
        "Could not safely recognize the trigger block. No changes saved."
    )

old_case = '''          case "${GITHUB_REF_NAME}" in
            master) echo "namespace=dev" >> "$GITHUB_OUTPUT" ;;
            pre-release/v*) echo "namespace=preprod" >> "$GITHUB_OUTPUT" ;;
            release/v*) echo "namespace=release" >> "$GITHUB_OUTPUT" ;;
          esac'''

new_case = '''          case "${GITHUB_REF_NAME}" in
            main|master) echo "namespace=dev" >> "$GITHUB_OUTPUT" ;;
            pre-release/v*) echo "namespace=preprod" >> "$GITHUB_OUTPUT" ;;
            release/v*) echo "namespace=release" >> "$GITHUB_OUTPUT" ;;
          esac'''

if old_case in s:
    s = s.replace(old_case, new_case, 1)
elif 'main|master)' not in s:
    raise SystemExit(
        "Could not safely recognize the namespace mapping. No changes saved."
    )

old_condition = "if: github.event_name != 'workflow_dispatch'"
new_condition = (
    "if: github.event_name != 'workflow_dispatch' "
    "|| inputs.rollback_namespace == ''"
)

count = s.count(old_condition)
if count:
    if count != 2:
        raise SystemExit(
            f"Expected 2 build-job conditions, found {count}. No changes saved."
        )
    s = s.replace(old_condition, new_condition)

if s.count(new_condition) != 2:
    raise SystemExit(
        "Build-job conditions were not patched as expected. No changes saved."
    )

p.write_text(s)
PY

echo "==> Checking patch..."
git diff --check

echo "==> Reviewing changes..."
git --no-pager diff -- "$WORKFLOW"

echo
read -r -p "Commit and push these workflow changes to origin/main? [y/N] " answer
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
  echo "Changes are applied locally but not committed or pushed."
  echo "Backup: $BACKUP"
  trap - ERR
  exit 0
fi

git add "$WORKFLOW"
git commit -m "ci: enable main branch workflow triggers"
git push origin main

rm -f "$BACKUP"
trap - ERR

echo
echo "SUCCESS: Workflow updated and pushed to main."
echo "Check: https://github.com/shabbiralam1999/DevOps-Assignment/actions"
