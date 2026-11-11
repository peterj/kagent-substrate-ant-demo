#!/usr/bin/env bash

show_command() {
  printf '\n$' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
}
run_command() { show_command "$@"; "$@"; }
exec_command() { show_command "$@"; exec "$@"; }
show_manifest() {
  printf '\nManifest: %s\n' "$1" >&2
  if [[ "$1" == *.json ]]; then
    ruby -rjson -ryaml -e 'puts YAML.dump(JSON.parse(File.read(ARGV.fetch(0))))' "$1" >&2
  else
    cat "$1" >&2
  fi
}
apply_manifest() {
  show_manifest "$1"
  run_command kubectl apply -f "$1"
}
