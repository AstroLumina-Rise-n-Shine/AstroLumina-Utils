# AstroLumina-Utils

Operational helper scripts for the AstroLumina workspace (environment bring-up,
branch housekeeping).

Documentation lives in the repository wiki:
https://github.com/AstroLumina-Rise-n-Shine/AstroLumina-Utils/wiki

## Usage

### bringup.sh — one-environment bring-up (development|staging|production)

Interactive on purpose: every command is printed first and runs only after you
press Enter. Never holds or pastes Enter for you.

```bash
./bringup.sh [development|staging|production]   # no argument -> it asks
```

The script resolves the workspace root in this order:

1. an exported `WORKSPACE_ROOT` (wins over everything),
2. the script's own directory when it contains `AstroLumina-Terraform` and
   `AstroLumina-Ansible` (legacy layout),
3. the parent of the script directory (current layout: `AstroLumina-Utils`
   is a sibling of the other repos in the workspace).

Requires an interactive terminal and up-to-date `main` in the source repos.

### clean_branches.sh — workspace branch housekeeping

Syncs every git repository directly under the workspace root — including
hidden ones such as `.github` — then offers to delete local branches whose
upstream is gone (`pull` after `fetch --prune` marked `[gone]`).

**Safe first step — always start with the dry-run.** It performs no deletions
and asks no confirmations (so it needs no TTY):

```bash
./clean_branches.sh --dry-run   # report only: what WOULD happen
./clean_branches.sh             # real run: needs a TTY, asks [Y/n] per branch
# optionally seed it: WORKSPACE_ROOT=/path/to/workspace ./clean_branches.sh
```

Destructive runs refuse to start without an interactive terminal. The default
answer is Yes, so a plain Enter deletes the branch; `main`/`master` and the
currently checked-out branch are always kept. Each repo also gets
`fetch.prune=true` so future manual fetches keep pruning.

## Wiki

Full documentation (workspace layout, environment bring-up walkthrough):
https://github.com/AstroLumina-Rise-n-Shine/AstroLumina-Utils/wiki

