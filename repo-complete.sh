#!/usr/bin/env bash
# repo-complete — the composer's ctrl-r autocomplete. Picks an open repo via
# fzf and prints the composer query rewritten with `>name ` as its repo
# token (replacing an existing leading token). Prints the query unchanged on
# cancel, so the composer's transform-query is always safe to apply.

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

query=$*

choice=$(worktrunk_open_repos | fzf --with-nth=2 --delimiter='\t' \
  --reverse --no-info --border=rounded \
  --prompt='repo ❯ ' --header='target repository · ↵ insert · esc keep typing')
if [[ -z $choice ]]; then
  printf '%s' "$query"
  exit 0
fi
name=${choice#*$'\t'}

# Drop an existing >token from the front of the query, wherever it sits among
# the other leading grammar tokens.
rest=$query
out=''
while :; do
  rest=${rest#"${rest%%[![:space:]]*}"}
  first=${rest%%[[:space:]]*}
  [[ -z $first ]] && break
  if [[ $first == '>'?* ]]; then
    rest=${rest#"$first"}
    continue
  fi
  if [[ $first == @* || $first =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*:$ ]]; then
    out+="$first "
    rest=${rest#"$first"}
    continue
  fi
  break
done
rest=${rest#"${rest%%[![:space:]]*}"}

printf '>%s %s%s' "$name" "$out" "$rest"
