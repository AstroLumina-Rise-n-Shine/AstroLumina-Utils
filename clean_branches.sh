#!/usr/bin/env bash
# ============================================================================
# AstroLumina workspace branch housekeeping.
#
# Walks EVERY git repository directly under the workspace root -- including
# hidden ones such as .github -- and for each one:
#   1. checks out the default branch (main/master; otherwise skips),
#   2. sets fetch.prune=true, then fetches with --prune,
#   3. fast-forwards the checked-out branch to its upstream,
#   4. reports local branches whose remote counterpart is gone (typically
#      branches removed after a PR merge), then asks what to delete; the
#      default answer is Yes, so a plain Enter deletes it.
#
# Usage:
#   ./clean_branches.sh           # destructive: deletes branches, needs a TTY
#   ./clean_branches.sh --dry-run # safe first step: report mode
#
# --dry-run performs NO deletions and asks NO confirmations, so it needs no
# interactive terminal. Run it first to see what a real run would decide,
# then run without the flag when you are happy with the report.
#
# The workspace root is resolved exactly like bringup.sh:
#   1. an exported WORKSPACE_ROOT wins over everything,
#   2. else the script directory itself when it contains
#      AstroLumina-Terraform and AstroLumina-Ansible (legacy layout where
#      the script sat in the workspace root),
#   3. else the parent of the script directory (the AstroLumina-Utils
#      checkout lives as a sibling of the other repos).
# ============================================================================
set -u

DRY_RUN=0
case "${1:-}" in
  "")     DRY_RUN=0 ;;
  --dry-run|-n) DRY_RUN=1 ;;
  *) echo "error: unknown argument '$1' (usage: $0 [--dry-run])" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Workspace-root detection (same precedence as in bringup.sh).
if [ -n "${WORKSPACE_ROOT:-}" ]; then
  # An explicit export wins; normalize a possible trailing slash.
  WORKSPACE_ROOT="${WORKSPACE_ROOT%/}"
elif [ -d "$SCRIPT_DIR/AstroLumina-Terraform" ] \
  && [ -d "$SCRIPT_DIR/AstroLumina-Ansible" ]; then
  WORKSPACE_ROOT="$SCRIPT_DIR"
else
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# The destructive run deletes branches based on prompt answers, so it must
# never run non-interactively: without a TTY there is nobody to answer and
# an unreadable stdin would silently resolve to the Yes default. The dry
# run mutates nothing and asks nothing, so it is allowed without a TTY.
if [ "$DRY_RUN" -eq 0 ] && [ ! -t 0 ]; then
  echo "error: destructive run needs an interactive terminal (stdin is not a tty); use --dry-run for a safe look" >&2
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "*** DRY RUN -- no deletions, no confirmations; report only. ***"
fi
echo "workspace root: ${WORKSPACE_ROOT}"

# Two glob patterns are needed because bash globs never match dotfiles:
#   */          matches all normal directories (AstroLumina-Terraform, ...)
#   .[!.]*/     matches hidden directories (.github) but not . and ..
# Unmatched patterns expand to a literal string, which the -d test below
# filters out.
for dir in "$WORKSPACE_ROOT"/*/ "$WORKSPACE_ROOT"/.[!.]*/; do
  [ -d "$dir" ] || continue
  [ -d "${dir}.git" ] || continue
  repo="$(basename "$dir")"
  echo "=== ${repo} ================="
  echo "  path:   ${dir}"

  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    echo "  skip: working tree has uncommitted changes"
    continue
  fi

  # Move to the default branch before fetching and pulling: the sync is only
  # meaningful on main, and the stale-branch scan below must never treat the
  # feature branch we happen to sit on as worth keeping. A failed checkout
  # (dirty tree blocking the switch, no main/master yet) skips the repo --
  # never touch a working tree we cannot safely leave.
  if ! git -C "$dir" checkout --quiet main 2>/dev/null && ! git -C "$dir" checkout --quiet master; then
    echo "  skip: cannot switch to main/master (dirty tree or missing default branch?)"
    continue
  fi

  current="$(git -C "$dir" branch --show-current)"
  echo "  branch: ${current}"

  # Make fetch --prune sticky on the repo so future manual fetches stay
  # pruned as well. This must land BEFORE the fetch itself.
  git -C "$dir" config fetch.prune true
  echo "  fetch.prune=true configured"

  head_before="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)"
  if ! git -C "$dir" fetch --prune --quiet; then
    echo "  skip: fetch failed"
    continue
  fi

  # Fast-forward the checked-out branch to its remote state. A failure here
  # (no upstream, diverged history) is not fatal: the stale-branch cleanup
  # below works off the fetched refs and can still proceed.
  if ! git -C "$dir" pull --ff-only --quiet; then
    echo "  pull: DID NOT fast-forward (no upstream or diverged?), continuing with cleanup"
  else
    head_after="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)"
    echo "  pull: fast-forward ${head_before} -> ${head_after}"
  fi

  # Local branches whose upstream ref disappeared (": gone]" tracking state).
  gone="$(git -C "$dir" for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads \
    | awk '$2 == "[gone]" {print $1}')"

  if [ -z "$gone" ]; then
    echo "  stale branches: none"
    continue
  fi

  echo "  stale branches (upstream gone):"
  while IFS= read -r gb; do
    [ -n "$gb" ] || continue
    echo "    - $gb"
  done <<< "$gone"

  # Deletion decisions. Protected/checked-out branches are always kept;
  # everything else is reported in dry-run mode or asked for confirmation
  # in a destructive run.
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue

    if [ "$branch" = "$current" ]; then
      echo "  keep '${branch}' (currently checked out)"
      continue
    fi
    case "$branch" in
      main|master)
        echo "  keep '${branch}' (protected)"
        continue
        ;;
    esac

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  dry-run: would delete '${branch}' (re-run without --dry-run to confirm)"
      continue
    fi

    printf "  Delete local branch '%s'? [Y/n] " "$branch"
    # Explicit </dev/tty: stdin inside this loop is the branch list itself
    # (herestring below), so the prompt must read from the terminal.
    read -r answer < /dev/tty || answer=""
    if [ -z "$answer" ] || [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      if git -C "$dir" branch -D "$branch" --quiet; then
        echo "  deleted '${branch}'"
      else
        echo "  FAILED to delete '${branch}'"
      fi
    else
      echo "  keeping '${branch}'"
    fi
  done <<< "$gone"
done

echo "done"
