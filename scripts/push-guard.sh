#!/usr/bin/env bash
# Push guard for pushcart-web's repo hygiene.
#
# `pos-contract.yml` guards the SCANnCART contract; this guard is for classes of
# content that must never travel by push. It reads only ADDED lines of the
# pushed range (PUSHGUARD_BEFORE-like base..HEAD), so a history cleaned earlier
# never re-fails and content the push merely keeps is never judged — a guard
# that scans everything becomes the noise that gets disabled. The rule set:
#
#   the CLI's secret-key constant      — the Supabase CLI prints it into
#                                       captured setup output; the value is a
#                                       constant, but once committed it trips
#                                       GitHub push protection on every later
#                                       push, so it is dead weight at best.
#   Supabase API-key JWT literals     — anon/service_role key JWTs carry the
#                                       constant base64url payload prefix
#                                       `{"iss":"supabase","ref":`. Matching
#                                       the payload catches both key types
#                                       regardless of their JWT secret. The
#                                       SQL role `service_role` in GRANT
#                                       statements is legitimate and is
#                                       deliberately NOT a match.
#   tracked paths ending .log         — logs are machine output; one of them
#                                       proved the leak path once
#                                       (supabase-start.log in a docs commit).
#                                       They belong on disk, not in history.
#
# The flag construction below is deliberately split (never a literal in this
# file) so the script does not itself trip the scan on the commit that adds it.
# Failures name the file and the diff line via the hunk header — the offending
# value is never echoed, because CI logs are public.
#
# Usage:
#   push-guard.sh [--selftest]
#   push-guard.sh <base-sha> <head-sha>     (base empty/missing scans the branch)

set -uo pipefail

# ---- patterns, assembled so this file carries no literal --------------------
S1="sb_"; S2="secret_"; P_SECRET="${S1}${S2}"
J1="eyJpc3MiOiJz"; J2="dXBhYmFzZSIsInJlZiI6"; P_JWT="${J1}${J2}"

# ---- the scanner: consumes a -U0 diff on stdin, matches on added lines ------
scan_diff () {
  awk -v p_secret="$P_SECRET" -v p_jwt="$P_JWT" '
    /^diff --git /            { path = "" }
    /^\+\+\+ /                { path = substr($0, 7) }
    /^@@ /                    {
      h = $0; sub(/^[^+]*\+/, "", h); sub(/[^0-9].*$/, "", h)
      newn = h + 0
    }
    /^\+[^+]|^\+$/ {
      newn++
      if (index($0, p_secret) != 0 || index($0, p_jwt) != 0) {
        printf "%s:%d\n", path, newn
      }
    }
  '
}

# ---- self-test: synthetic diff through the same scanner --------------------
selftest() {
  local sample; sample=$(printf '%s%s' "$S1" "${S2}SAMPLExxx")
  local jwt_sample; jwt_sample=$(printf '%s%s' "$J1" "${J2}rest")
  local diff
  diff=$(printf '%s\n' \
    'diff --git a/ok.txt b/ok.txt' \
    '--- a/ok.txt' \
    '+++ b/ok.txt' \
    '@@ -1,0 +1,1 @@' \
    '+grant execute on f to service_role;' \
    'diff --git a/bad.txt b/bad.txt' \
    '--- a/bad.txt' \
    '+++ b/bad.txt' \
    '@@ -1,0 +1,2 @@' \
    "+${sample}" \
    "+${jwt_sample}")
  local found; found=$(printf '%s\n' "$diff" | scan_diff)
  echo "$found" | grep -q '^bad.txt:2$' || { echo "selftest: missed the sb_secret line"; return 1; }
  echo "$found" | grep -q '^bad.txt:3$' || { echo "selftest: missed the key-JWT line"; return 1; }
  echo "$found" | grep -q 'ok.txt' && { echo "selftest: flagged a legitimate service_role grant"; return 1; }
  echo "selftest: 2 detections, 1 exemption — as designed"
}

# ---- log-path rule: any added or refreshed tracked *.log path ---------------
log_paths () {
  local base="$1" head="$2"
  git diff --diff-filter=ACMR --name-only "$base" "$head" -- '*.log' 2>/dev/null
}

# ---- dispatch ---------------------------------------------------------------
case "${1:-}" in
  --selftest) selftest; exit $? ;;
esac

HEAD_SHA="${2:-}"
if [ -z "${HEAD_SHA:-}" ]; then
  echo "usage: push-guard.sh [--selftest | <base-sha> <head-sha>]" >&2
  exit 2
fi

BASE_SHA="${1:-}"
MODE=range
if [ -z "$BASE_SHA" ] || ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  # First push of a branch (event.before is the zero sha) or a compacted
  # base: fall back to the whole branch — its history is committed content,
  # which is exactly what an initial push introduces.
  MODE=branch
  # Empty-tree diff: an initial push introduces the root commit's content too.
  BASE_SHA=$(git hash-object -t tree /dev/null)
  echo "push-guard: no prior commit for this branch — scanning the whole branch"
fi

# introduced secrets: added lines anywhere in the range
hits=$(git diff --diff-filter=ACMR -U0 "$BASE_SHA" "$HEAD_SHA" | scan_diff)
loghits=$(log_paths "$BASE_SHA" "$HEAD_SHA")

status=0
if [ -n "$hits" ]; then
  status=1
  echo "push-guard: Supabase key material introduced by this push:" >&2
  echo "$hits" | while IFS= read -r h; do
    echo "  $h — value withheld; the line must not enter history" >&2
  done
fi
if [ -n "$loghits" ]; then
  status=1
  echo "push-guard: tracked log files introduced or refreshed by this push:" >&2
  echo "$loghits" | sed 's/^/  /' >&2
fi

if [ "$status" = 0 ]; then
  echo "push-guard: clean (${MODE} scan of ${BASE_SHA:0:12}..${HEAD_SHA:0:12})"
else
  echo "push-guard: rejected — untrack/remove the content: delete the value from the" >&2
  echo "  commit(s) before pushing again (rebase/edit the range; untrack logs with" >&2
  echo "  'git rm --cached <file>' and keep them on disk)." >&2
fi
exit $status
