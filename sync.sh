#!/bin/bash
#
# sync.sh — publish allowlisted Hermes skills to this repo.
#
#   1. rebuild ./skills from the allowlist in skills.txt
#   2. SECRET SCAN — abort (no commit, no push) if anything key-shaped is found
#   3. commit + push
#
# Usage:  ./sync.sh [--dry-run] [--no-push]
#
set -uo pipefail

SRC="$HOME/.hermes/skills"
REPO="$(cd "$(dirname "$0")" && pwd)"
LIST="$REPO/skills.txt"
DEST="$REPO/skills"
UPSTREAM="$SRC"

DRY=0; NOPUSH=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-push) NOPUSH=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# --- secrets we must never publish -----------------------------------------
PAT='sk-[A-Za-z0-9]{28,}'
PAT="$PAT"'|ghp_[A-Za-z0-9]{30,}'
PAT="$PAT"'|gho_[A-Za-z0-9]{30,}'
PAT="$PAT"'|github_pat_[A-Za-z0-9_]{50,}'
PAT="$PAT"'|tskey-[a-z]+-[A-Za-z0-9]{20,}'
PAT="$PAT"'|apikey_[a-f0-9]{30,}'
PAT="$PAT"'|AIza[A-Za-z0-9_-]{33}'
PAT="$PAT"'|xox[baprs]-[A-Za-z0-9-]{20,}'
PAT="$PAT"'|hf_[A-Za-z0-9]{30,}'
PAT="$PAT"'|r8_[A-Za-z0-9]{30,}'
PAT="$PAT"'|-----BEGIN [A-Z ]*PRIVATE KEY'
PAT="$PAT"'|Bearer [A-Za-z0-9._-]{40,}'

echo "════════ Hermes skills sync ════════"
echo "source : $SRC"
echo "repo   : $REPO"
echo

# ---------- 1. rebuild skills/ ----------
[ -f "$LIST" ] || { echo "❌ missing allowlist: $LIST" >&2; exit 1; }

echo "── rebuilding skills/ from allowlist ──"
rm -rf "$DEST"
mkdir -p "$DEST"
n=0; miss=0
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | xargs)"
  [ -z "$line" ] && continue
  if [ -d "$UPSTREAM/$line" ]; then
    mkdir -p "$DEST/$(dirname "$line")"
    rsync -a \
      --exclude '.DS_Store' --exclude '__pycache__' --exclude '*.pyc' \
      --exclude '*.log' --exclude '*.log.*' --exclude '.git' \
      "$UPSTREAM/$line" "$DEST/$(dirname "$line")/"
    n=$((n+1))
    printf '   ✓ %s\n' "$line"
  else
    printf '   ⚠️  not found, skipped: %s\n' "$line"
    miss=$((miss+1))
  fi
done < "$LIST"
echo "   → $n skill(s) staged, $miss missing"
echo

# ---------- 2. secret scan (hard gate) ----------
echo "── secret scan ──"
HITS="$(grep -rIEl "$PAT" "$DEST" 2>/dev/null)"
if [ -n "$HITS" ]; then
  echo "❌❌ SECRETS DETECTED — refusing to commit/push:"
  echo "$HITS" | sed 's|^|     |'
  echo
  echo "   Redact these first, then re-run. (Nothing was committed.)"
  exit 1
fi
echo "   ✅ no key-shaped strings found"
echo

# ---------- dry-run stops here ----------
if [ "$DRY" = 1 ]; then
  echo "── staged payload ──"
  printf '   size : %s\n' "$(du -sh "$DEST" 2>/dev/null | cut -f1)"
  printf '   files: %s\n' "$(find "$DEST" -type f 2>/dev/null | wc -l | tr -d ' ')"
  echo
  echo "── dry-run complete: nothing committed ──"
  exit 0
fi

# ---------- 3. commit + push ----------
cd "$REPO" || exit 1

if [ ! -d .git ]; then
  echo "── initialising git ──"
  git init -q
  git branch -M main
  echo "   ✓ git initialised on main"
fi

git add -A
if git diff --cached --quiet 2>/dev/null; then
  echo "── nothing changed — no commit ──"
  exit 0
fi

echo "── changes ──"
git diff --cached --stat | tail -20

MSG="sync skills $(date '+%Y-%m-%d %H:%M') ($n skill(s))"
git commit -q -m "$MSG" && echo "✓ committed: $MSG"

if [ "$NOPUSH" = 1 ]; then
  echo "── --no-push: stopping before push ──"
  exit 0
fi

if git remote get-url origin >/dev/null 2>&1; then
  if git push -q origin HEAD; then
    echo "✓ pushed to origin"
  else
    echo "❌ push failed"
    echo "   hint: 'could not read Username for https://github.com' = no git credential"
    echo "   helper in a non-interactive shell. Fix once, then re-run:"
    echo "     gh auth setup-git && git push origin HEAD"
    exit 1
  fi
else
  echo "⚠️  no 'origin' remote yet — create the GitHub repo, then:"
  echo "     git -C \"$REPO\" remote add origin git@github.com:<you>/hermes-skills.git"
  echo "     git -C \"$REPO\" push -u origin main"
fi
