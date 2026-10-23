#!/bin/sh
set -eu

title="$1"
status_dir="${2:-}"
tab="$(printf '\t')"

list() {
  if [ -n "$status_dir" ]; then
    for f in "$status_dir"/*; do
      awk -F': ' '/^Package:/ {p = $2} /^Version:/ {v = $2} END {if (p != "") print p "\t" v}' "$f"
    done
  else
    dpkg-query -W -f='${Package}\t${Version}\n'
  fi
}

licenses() {
  grep -h '^License:' "/usr/share/doc/$1/copyright" 2>/dev/null \
    | sed 's/^License:[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\001-\011\013-\037"\\' \
    | sed '/^$/d' | sort -u | head -5 | tr '\n' ',' | sed 's/,$//; s/,/, /g'
}

printf '{"title":"%s","note":"%s","packages":[' "$title" \
  "Die vollständigen Lizenz- und Copyright-Angaben jedes Systempakets liegen im Image unter /usr/share/doc/<paket>/copyright."
list | sort -u | {
  first=1
  while IFS="$tab" read -r name version; do
    [ -n "$name" ] || continue
    license="$(licenses "$name")"
    [ -n "$license" ] || license="siehe /usr/share/doc/$name/copyright"
    [ "$first" -eq 1 ] && first=0 || printf ','
    printf '{"name":"%s","version":"%s","license":"%s","text":""}' "$name" "$version" "$license"
  done
}
printf ']}\n'
