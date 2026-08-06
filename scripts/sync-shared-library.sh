#!/usr/bin/env bash
# ==============================================================================
# sync-shared-library.sh
# ==============================================================================
# Mirrors 05-Jenkins/vars/ into a dedicated Jenkins shared-library repository.
#
# WHY THIS EXISTS
# ---------------
# Jenkins Global Pipeline Libraries require `vars/` at the ROOT of the repository
# they are loaded from. This project keeps it at 05-Jenkins/vars/ so the CI code
# lives beside everything else it relates to — which Jenkins cannot consume
# directly. This script bridges the two.
#
# USAGE
#   ./scripts/sync-shared-library.sh ~/repos/jenkins-shared-library
#
# One-time setup:
#   1. Create an empty GitHub repo named jenkins-shared-library
#   2. Clone it locally
#   3. Run this script, pointing at the clone
#   4. Configure it in Jenkins:
#        Manage Jenkins → System → Global Pipeline Libraries
#        Name: shared-library · Default version: main
# ==============================================================================

set -euo pipefail

# -e  exit on error · -u  error on undefined variable · -o pipefail  catch
# failures anywhere in a pipe, not just the last command.

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

info()  { printf "${BLUE}==>${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}!${NC} %s\n" "$1"; }
die()   { printf "${RED}✗${NC} %s\n" "$1" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------
LIB_REPO="${1:-}"

if [[ -z "$LIB_REPO" ]]; then
    die "usage: $0 <path-to-shared-library-repo>

Example:
    $0 ~/repos/jenkins-shared-library"
fi

# Resolve to an absolute path so the later `cd` cannot misbehave.
LIB_REPO="$(cd "$LIB_REPO" 2>/dev/null && pwd)" \
    || die "not a directory: $1"

# Locate this project's root from the script's own location, so the script works
# regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_VARS="$PROJECT_ROOT/05-Jenkins/vars"

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------
[[ -d "$SOURCE_VARS" ]]      || die "source not found: $SOURCE_VARS"
[[ -d "$LIB_REPO/.git" ]]    || die "not a git repository: $LIB_REPO"

info "Source : $SOURCE_VARS"
info "Target : $LIB_REPO/vars"

# Refuse to overwrite a target with uncommitted work.
if [[ -n "$(git -C "$LIB_REPO" status --porcelain)" ]]; then
    warn "Target repository has uncommitted changes:"
    git -C "$LIB_REPO" status --short
    read -rp "Continue anyway? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || die "aborted"
fi

# ------------------------------------------------------------------------------
# Sync
# ------------------------------------------------------------------------------
info "Syncing…"

mkdir -p "$LIB_REPO/vars"

if command -v rsync >/dev/null 2>&1; then
    # --delete removes steps that were deleted from the source. Without it, a
    # renamed step leaves the old file behind and Jenkins keeps offering it.
    rsync -a --delete "$SOURCE_VARS/" "$LIB_REPO/vars/"
else
    # Fallback for environments without rsync (some Git Bash installs).
    rm -rf "${LIB_REPO:?}/vars"
    cp -r "$SOURCE_VARS" "$LIB_REPO/vars"
fi

# NOTE: README.md in the target repo is deliberately NOT touched.
#
# The library repository is shared: it also holds the foundational steps
# (buildApp, buildImage, deployOnK8s, updateGitOpsRepo) used by the internship
# labs, and its README documents BOTH generations. Regenerating it here would
# silently delete that documentation on every sync.
#
# If you maintain a dedicated, single-purpose library repo instead, generating
# the README is reasonable — but then it should also carry a "GENERATED, do not
# edit" banner.
ok "Files synced (README.md left untouched)"

# ------------------------------------------------------------------------------
# Commit and push
# ------------------------------------------------------------------------------
cd "$LIB_REPO"
git add vars

# `git diff --cached --quiet` exits 0 when nothing is staged. Without this
# guard, a no-op run fails on "nothing to commit".
if git diff --cached --quiet; then
    ok "Already up to date — nothing to commit."
    exit 0
fi

info "Changes to be committed:"
git diff --cached --stat

SRC_SHA="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

git commit -m "chore: sync shared library from CloudDevOpsProject@${SRC_SHA}

Mirrored from 05-Jenkins/vars/.
Do not edit this repository directly — changes are overwritten on the next sync."

info "Pushing…"
git push

ok "Shared library updated. Jenkins picks up 'main' on the next build."
