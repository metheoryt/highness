#!/usr/bin/env bash
# prefs.sh — a person's working preferences: where they live, and what the close step proposes.
#
# highness reads the person's own store; it does not own one. The personal config key
# `preferences` (the user file's top level only, never a repo file or an overlay: it picks where
# lines get written) is one path or a list of paths, each a file or a directory (its *.md files,
# followed through symlinks). `~` and `~/…` are expanded; a relative path is skipped with a
# warning. Unset: one default file, ${XDG_CONFIG_HOME:-~/.config}/highness/preferences.md.
#
#   prefs.sh paths                    the preference files that exist, one absolute path per line:
#                                     what the worker spec and the ask cite (never their text)
#   prefs.sh targets                  where lines may be written: every file entry (existing or
#                                     not), each directory's *.md files, and the default file
#   prefs.sh propose <KEY>            proposed lines from the ticket's choice records, grouped
#                                     under "## <target file>": the file the picked option leans on
#                                     when it names one of the targets, else the first target. Raw
#                                     material: the coordinator rewords them before the diff
#   prefs.sh diff <file> <lines> [--under '<heading>']
#                                     what write would change, as a unified diff; writes nothing
#   prefs.sh write <file> <lines> [--under '<heading>']
#                                     add the lines (those not already in the file) at the end, or
#                                     at the end of the section under <heading> (created at the
#                                     end when missing). Only to a file `targets` lists. Run only
#                                     on the person's yes to the diff
#   prefs.sh repeats [--min N]        a choice repeated across N (default 2) or more tickets, TSV:
#                                     basis, value, tickets, keys (comma-separated). basis
#                                     `leans_on`: the picked options lean on the same line of one
#                                     of the person's preference files; `picked`: the same option
#                                     name was picked. Only choices that took an offered option
#   prefs.sh draft-rule <basis> <value> [--root R]
#                                     a team-rule proposal for one repeat, as the body of a pull
#                                     request: first line `target: <file>` (crew.team_rules read at
#                                     R, default `crew.sh root`) or `target: none`, then the rule
#                                     and its evidence. Never the person's verbatim replies, never
#                                     a home path: the PR goes to the team's repo
#
# Nothing here leaves the machine: the person's own sync carries the files from there.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.sh"
CREW="$HERE/crew.sh"
DEFAULT="${XDG_CONFIG_HOME:-$HOME/.config}/highness/preferences.md"

die() { printf 'prefs: %s\n' "$*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die 'jq is required'

# The configured entries, one per line, ~ expanded; nothing when unset.
entries() {
  local e
  bash "$CONFIG" get --user '.preferences // empty | if type == "array" then . else [.] end | map(strings) | .[]' 2>/dev/null \
    | while IFS= read -r e; do
        case "$e" in
          '') continue ;;
          '~') e=$HOME ;;
          '~/'*) e="$HOME/${e#\~/}" ;;
          /*) ;;
          *) printf 'prefs: skipping relative path in preferences: %s\n' "$e" >&2; continue ;;
        esac
        printf '%s\n' "${e%/}"
      done
}

configured() { bash "$CONFIG" has --user '.preferences' >/dev/null 2>&1 && [ -n "$(entries 2>/dev/null)" ]; }

# Files of the entries: a directory gives its *.md files, sorted; a file entry is kept as is.
files() {
  local e
  entries | while IFS= read -r e; do
    if [ -d "$e" ]; then find -H "$e" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort
    else printf '%s\n' "$e"; fi
  done
}

cmd_paths() {
  local f
  if configured; then files | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done
  else [ -f "$DEFAULT" ] && printf '%s\n' "$DEFAULT"; fi
  return 0
}

cmd_targets() { { configured && files; printf '%s\n' "$DEFAULT"; } | awk '!seen[$0]++'; }

# --- propose

cmd_propose() {
  [ $# -eq 1 ] || die 'usage: propose <KEY>'
  local t
  t=$(cmd_targets | jq -Rsc 'split("\n") | map(select(. != ""))')
  bash "$CREW" choices "$1" | jq -rs --argjson t "$t" '
    def norm: ascii_downcase | gsub("[^a-z0-9]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    def one: gsub("[\\s]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    def q: ((.question // "") | if . == "" then null else . end)
           // ((.ask_body // "") | split("\n") | map(select(test("\\S"))) | first // "")
           | one;
    def opt: . as $c | ($c.options // []) | map(select((.name // "" | norm) == ($c.picked // "" | tostring | norm))) | first // {};
    def target: (opt.leans_on // "") as $l
      | ([ $t[] | . as $f | ($f | split("/") | last) as $b | select($l | contains($b)) ] | first) // $t[0];
    [ .[] | select(.took != null) | {target: target, line: (
        "- " + q + ": "
        + (if .took == "option" then "chose " + (.picked // "?" | tostring | one)
             + ((opt.leans_on // "") | if . != "" and (norm | startswith("no rule") | not) then " (leans on " + one + ")" else "" end)
           elif .took == "own" then "answered with their own option: " + (.reply // .picked // "" | tostring | one)
           else "rejected the framing: " + (.reply // "" | tostring | one) end)
        + " — " + .key) } ]
    | group_by(.target)[] | "## " + .[0].target, (.[] | .line), ""'
}

# --- diff / write

# The file with the lines added: <file> <lines> <heading or empty> -> stdout.
merged() {
  local file=$1 lines=$2 under=$3
  { [ -f "$file" ] && cat "$file"; true; } | awk -v linesf="$lines" -v under="$under" '
    BEGIN { while ((getline l < linesf) > 0) { if (l ~ /[^ \t]/) add[++n] = l } }
    { body[++m] = $0; have[$0] = 1 }
    END {
      k = 0
      for (i = 1; i <= n; i++) if (!(add[i] in have) && !(add[i] in dup)) { new[++k] = add[i]; dup[add[i]] = 1 }
      at = m; hdr = 0
      if (under != "") {
        for (i = 1; i <= m; i++) if (body[i] == under) { hdr = i; break }
        if (hdr) { at = hdr; for (i = hdr + 1; i <= m && body[i] !~ /^#/; i++) if (body[i] ~ /[^ \t]/) at = i }
      }
      for (i = 1; i <= at; i++) print body[i]
      if (k) {
        if (under != "" && !hdr) { if (m && body[m] ~ /[^ \t]/) print ""; print under; print "" }
        else if (!hdr && m && body[m] ~ /[^ \t]/ && body[m] !~ /^[-*] /) print ""
        for (i = 1; i <= k; i++) print new[i]
        if (hdr && at < m && body[at + 1] ~ /^#/) print ""
      }
      for (i = at + 1; i <= m; i++) print body[i]
    }'
}

parse_dw() { # sets FILE LINES UNDER from <file> <lines> [--under <heading>]
  FILE=''; LINES=''; UNDER=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --under) UNDER=${2:-}; shift 2 ;;
      -*) die "unknown argument '$1'" ;;
      *) if [ -z "$FILE" ]; then FILE=$1; elif [ -z "$LINES" ]; then LINES=$1; else die 'usage: diff|write <file> <lines> [--under <heading>]'; fi; shift ;;
    esac
  done
  [ -n "$FILE" ] && [ -n "$LINES" ] || die 'usage: diff|write <file> <lines> [--under <heading>]'
  [ -f "$LINES" ] || die "no lines file: $LINES"
  # diff refuses what write refuses, so a person never approves a change that cannot be applied.
  cmd_targets | grep -qxF "$FILE" || die "$FILE is not one of the preference files (prefs.sh targets)"
}

cmd_diff() {
  parse_dw "$@"
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/hi-prefs.XXXXXX") || die 'no temp file'
  merged "$FILE" "$LINES" "$UNDER" >"$tmp"
  if [ -f "$FILE" ]; then diff -u "$FILE" "$tmp" | sed "2s|^+++ .*|+++ $FILE (proposed)|"
  else diff -u /dev/null "$tmp" | sed "1s|^--- .*|--- $FILE (new)|; 2s|^+++ .*|+++ $FILE (proposed)|"; fi
  rm -f "$tmp"
  return 0
}

cmd_write() {
  parse_dw "$@"
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/hi-prefs.XXXXXX") || die 'no temp file'
  merged "$FILE" "$LINES" "$UNDER" >"$tmp"
  if [ -f "$FILE" ] && cmp -s "$FILE" "$tmp"; then rm -f "$tmp"; echo 'nothing to add'; return 0; fi
  mkdir -p "$(dirname "$FILE")" || { rm -f "$tmp"; die "write: cannot create $(dirname "$FILE")"; }
  # cat into the file, not mv over it: a store reached through a symlink stays a symlink.
  cat "$tmp" >"$FILE" || { rm -f "$tmp"; die "write: cannot write $FILE"; }
  rm -f "$tmp"
  printf 'written: %s\n' "$FILE"
}

# --- repeats / draft-rule

# The person's preference file basenames, as a JSON array (what a personal leans_on names).
basenames() { cmd_targets | awk -F/ '{ print $NF }' | jq -Rsc 'split("\n") | map(select(. != ""))'; }

# Every choice that took an offered option, with its basis values, one JSON object per line.
# A generic option name ("A", "Yes", "Option 2", "Recommended") says nothing across tickets, so it
# gives no `picked` basis.
chosen() {
  bash "$CREW" choices | jq -c --argjson b "$(basenames)" '
    def norm: ascii_downcase | gsub("[^a-z0-9]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    select(.took == "option" and (.picked // "") != "")
    | . as $c
    | (($c.options // []) | map(select((.name // "" | norm) == ($c.picked | tostring | norm))) | first // {}) as $o
    | ($o.leans_on // "" | tostring) as $l
    | {key, at, picked: ($c.picked | tostring), leans_on: $l,
       question: (($c.question // "") | if . == "" then (($c.ask_body // "") | split("\n") | map(select(test("\\S"))) | first // "") else . end),
       by: ((($c.picked | tostring | norm) as $p
            | if ($p | length) < 4 or ($p | test("^(option|variant|choice)? ?[a-z0-9]$|^(yes|no|ok|okay|recommended|the recommended one|default)$"))
              then [] else [{basis: "picked", value: $p}] end)
            + (if $l != "" and ($l | norm | startswith("no rule") | not) and any($b[]; . as $f | $l | contains($f))
               then [{basis: "leans_on", value: ($l | norm)}] else [] end))}'
}

cmd_repeats() {
  local min=2
  case "${1:-}" in --min) min=${2:-}; shift 2 ;; esac
  [ $# -eq 0 ] || die 'usage: repeats [--min N]'
  case "$min" in ''|*[!0-9]*) die "repeats: --min wants a number, got '$min'" ;; esac
  chosen | jq -rs --argjson min "$min" '
    [ .[] | . as $c | .by[] | {basis, value, key: $c.key} ]
    | group_by([.basis, .value])[]
    | (map(.key) | unique) as $keys
    | select(($keys | length) >= $min and .[0].value != "")
    | [.[0].basis, .[0].value, ($keys | length), ($keys | join(","))] | @tsv'
}

cmd_draft_rule() {
  local basis='' value='' root='' target rows
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) root=${2:-}; shift 2 ;;
      -*) die "unknown argument '$1'" ;;
      *) if [ -z "$basis" ]; then basis=$1; elif [ -z "$value" ]; then value=$1; else die 'usage: draft-rule <basis> <value> [--root R]'; fi; shift ;;
    esac
  done
  [ -n "$basis" ] && [ -n "$value" ] || die 'usage: draft-rule <basis> <value> [--root R]'
  case "$basis" in picked|leans_on) ;; *) die "draft-rule: basis is picked or leans_on, not '$basis'" ;; esac
  [ -n "$root" ] || root=$(bash "$CREW" root 2>/dev/null) || root=$(pwd -P)
  target=$(cd "$root" 2>/dev/null && bash "$CONFIG" get '.crew.team_rules' 2>/dev/null) || target=''
  rows=$(chosen | jq -sc --arg b "$basis" --arg v "$value" 'map(select(any(.by[]; .basis == $b and .value == $v)))')
  [ "$(printf '%s' "$rows" | jq length)" -gt 0 ] || die "draft-rule: no choice has $basis '$value' (prefs.sh repeats)"
  printf 'target: %s\n\n' "${target:-none}"
  printf '%s' "$rows" | jq -r --arg b "$basis" '
    def one: tostring | gsub("[\\s]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    (map(.key) | unique) as $keys
    | (if $b == "leans_on" then (.[0].leans_on | one) else "choose \"" + (.[0].picked | one) + "\"" end) as $rule
    | "## Proposed team rule",
      "",
      "- " + $rule,
      "",
      "## Why",
      "",
      "The same choice was made on \($keys | length) tickets (\($keys | join(", "))). One person choosing it each time is a preference; written here, it becomes the team'"'"'s, if the team agrees in review.",
      "",
      "| ticket | when | question | picked |",
      "|---|---|---|---|",
      (.[] | "| \(.key) | \(.at[0:10]) | \(.question | one | gsub("\\|"; "/") | .[0:140]) | \(.picked | one | gsub("\\|"; "/")) |")' \
    | awk -v h="$HOME" 'h != "" { while ((p = index($0, h)) > 0) $0 = substr($0, 1, p - 1) "~" substr($0, p + length(h)) } { print }'
}

case "${1:-}" in
  paths) cmd_paths ;;
  targets) cmd_targets ;;
  propose) shift; cmd_propose "$@" ;;
  diff) shift; cmd_diff "$@" ;;
  write) shift; cmd_write "$@" ;;
  repeats) shift; cmd_repeats "$@" ;;
  draft-rule) shift; cmd_draft_rule "$@" ;;
  *) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
