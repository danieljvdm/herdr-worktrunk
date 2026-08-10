#!/bin/sh
# repo-candidates — the composer's inline >repo completion source. Emits
# ">name" candidates while the query is a bare >token being typed at the
# front; emits nothing once the token is finished (a space follows) or the
# query is ordinary task text. Kept dependency-free and tiny: it runs on
# every keystroke via fzf's change:reload, so it must stay imperceptible.
q=$1
file=$2
case $q in
  '>'*' '*) exit 0 ;;
  '>'*) tok=${q#>} ;;
  *) exit 0 ;;
esac
grep -iF -- "$tok" "$file" 2>/dev/null | sed 's/^/>/'
