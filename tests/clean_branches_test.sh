#!/usr/bin/env bash
# ============================================================================
# Unit tests for clean_branches.sh (self-contained, plain bash, no bats).
#
# Builds a throwaway workspace in `mktemp -d` containing:
#   - a normal repo `AstroLumina-Demo` with a bare `origin`
#   - a hidden repo `.github` with its own bare `origin`
#   - a plain directory without .git, which the script must ignore
#
# Each repo gets:
#   - one branch that is pushed to origin and then deleted on the remote
#     (simulating a post-merge cleanup) -> must be reported as stale and
#     listed as "would delete" in dry-run mode;
#   - one local-only branch that was never pushed -> must never be reported
#     as stale and must still exist after the run.
#
# The script is only exercised in --dry-run mode: dry-run performs no
# deletions and needs no TTY, so the test never touches a destructive run.
#
# The suite exits non-zero if any assertion fails and prints a PASS/FAIL
# summary. The temp workspace is removed via a trap.
# ============================================================================
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_BRANCHES="${TESTS_DIR}/../clean_branches.sh"

if [ ! -f "$CLEAN_BRANCHES" ]; then
  echo "error: clean_branches.sh not found next to tests/ (${CLEAN_BRANCHES})" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
WORKSPACE="${TMP_ROOT}/workspace"
TAINTED=0 # 1 => TMP_ROOT already holds the workspace/results, so trap removes it

cleanup() {
  if [ "$TAINTED" -eq 1 ]; then
    rm -rf -- "$TMP_ROOT"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 1' INT TERM

PASS_COUNT=0
FAIL_COUNT=0

# check <description> <command...>  -- command success => PASS, failure => FAIL
check() {
  local desc="$1"
  shift
  if "$@"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "PASS: ${desc}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: ${desc}"
  fi
}

branch_exists() { # repo-dir branch-name
  git -C "$1" show-ref --verify --quiet "refs/heads/$2"
}

fetch_prune_is_true() { # repo-dir
  [ "$(git -C "$1" config fetch.prune)" = "true" ]
}

output_contains() { # literal-string
  printf '%s\n' "$OUTPUT" | grep -qF -- "$1"
}

output_lacks() { # literal-string
  ! printf '%s\n' "$OUTPUT" | grep -qF -- "$1"
}

# ----------------------------------------------------------------------------
# Fixture: create <workspace>/<name> as a repo with a bare origin hosted
# outside the workspace, where the script's directory walk cannot see it.
# ----------------------------------------------------------------------------
make_repo() {
  local name="$1"
  local repo="${WORKSPACE}/${name}"
  local origin="${TMP_ROOT}/remotes/${name}.git"

  git init -q --bare "$origin"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Clean Branches Test"
  printf '# %s\n' "$name" >"${repo}/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "initial commit on ${name}"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main
}

# ----------------------------------------------------------------------------
# Fixture branches.
#
# stale   : pushed to origin, then deleted on the remote (merge cleanup)
#           -> the pushed branch's upstream becomes "[gone]" and must be
#           reported by the script; it must not be deleted in dry-run.
# unpushed: created locally, never pushed -> no upstream at all, so the
#           script must NEVER report or delete it.
# ----------------------------------------------------------------------------
make_stale_branch() { # repo-dir branch-name
  local repo="$1" branch="$2"
  git -C "$repo" checkout -q -b "$branch"
  printf 'stale work\n' >"${repo}/stale.txt"
  git -C "$repo" add stale.txt
  git -C "$repo" commit -q -m "stale work on ${branch}"
  git -C "$repo" push -q -u origin "$branch"
  git -C "$repo" push -q origin --delete "$branch"
  # Prune the remote-tracking ref so this branch's upstream resolves to
  # "[gone]" even before the script runs its own fetch --prune.
  git -C "$repo" fetch -q --prune origin
  git -C "$repo" checkout -q main
}

make_unpushed_branch() { # repo-dir branch-name
  local repo="$1" branch="$2"
  git -C "$repo" checkout -q -b "$branch"
  printf 'local only\n' >"${repo}/local.txt"
  git -C "$repo" add local.txt
  git -C "$repo" commit -q -m "local-only work on ${branch}"
  git -C "$repo" checkout -q main
}

STALE='feature/merged-pr'
UNPUSHED='feature/never-pushed'

# ----------------------------------------------------------------------------
# Assemble the throwaway workspace.
# ----------------------------------------------------------------------------
mkdir -p "${TMP_ROOT}/remotes"
mkdir -p "$WORKSPACE"

make_repo "AstroLumina-Demo"
make_repo ".github"
make_repo "AstroLumina-Dirty"
mkdir -p "${WORKSPACE}/AstroLumina-Terraform" # plain dir, no .git -> must be skipped

for repo in \
  "${WORKSPACE}/AstroLumina-Demo" \
  "${WORKSPACE}/.github"; do
  make_stale_branch "$repo" "$STALE"
  make_unpushed_branch "$repo" "$UNPUSHED"
done

printf 'preserve this local change\n' >>"${WORKSPACE}/AstroLumina-Dirty/README.md"
TAINTED=1

echo "=== clean_branches.sh --dry-run (workspace: ${WORKSPACE}) ==="
# Dry-run performs no deletions and needs no TTY, so this is safe from any
# environment, including CI and a non-interactive shell.
OUTPUT="$(WORKSPACE_ROOT="$WORKSPACE" bash "$CLEAN_BRANCHES" --dry-run 2>&1)"
RUN_STATUS=$?
echo "$OUTPUT"
echo "==============================="
echo ""

# ----------------------------------------------------------------------------
# Assertions.
# ----------------------------------------------------------------------------
check "dry-run exits 0 without a TTY"                test "$RUN_STATUS" -eq 0
check "output names the demo repo"                   output_contains "=== AstroLumina-Demo ==="
check "output includes the hidden .github repo"      output_contains "=== .github ==="
check "dry-run banner is present"                    output_contains "DRY RUN"
check "stale-branch section is reported"             output_contains "stale branches (upstream gone):"
check "stale branch listed as would-delete (demo)"   output_contains "dry-run: would delete '${STALE}'"
check "stale branch listed as would-delete (.github)" output_contains "dry-run: would delete '${STALE}'"
check "unpushed branch never reported (demo)"        output_lacks "'${UNPUSHED}'"
check "unpushed branch never reported (.github)"     output_lacks "'${UNPUSHED}'"
check "unpushed branch absent from output entirely"  output_lacks "${UNPUSHED}"
check "fetch.prune=true set on demo repo"            fetch_prune_is_true "${WORKSPACE}/AstroLumina-Demo"
check "fetch.prune=true set on .github repo"         fetch_prune_is_true "${WORKSPACE}/.github"
check "dirty repo is skipped before checkout/fetch"  output_contains "skip: working tree has uncommitted changes"
check "dirty repo is not configured for pruning"     test -z "$(git -C "${WORKSPACE}/AstroLumina-Dirty" config --local --get fetch.prune)"
check "dirty repo keeps its local modification"      grep -qF "preserve this local change" "${WORKSPACE}/AstroLumina-Dirty/README.md"
check "plain dir without .git is ignored"            output_lacks "AstroLumina-Terraform"
check "dry-run deletes nothing: stale branch kept (demo)"     branch_exists "${WORKSPACE}/AstroLumina-Demo" "$STALE"
check "dry-run deletes nothing: stale branch kept (.github)"  branch_exists "${WORKSPACE}/.github" "$STALE"
check "unpushed branch still present after run (demo)"        branch_exists "${WORKSPACE}/AstroLumina-Demo" "$UNPUSHED"
check "unpushed branch still present after run (.github)"     branch_exists "${WORKSPACE}/.github" "$UNPUSHED"

# ----------------------------------------------------------------------------
# Summary.
# ----------------------------------------------------------------------------
echo ""
echo "=== clean_branches_test.sh summary ==="
echo "PASS: ${PASS_COUNT}"
echo "FAIL: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
exit 0
