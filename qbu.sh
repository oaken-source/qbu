#!/bin/bash

set -euo pipefail
[ -z "${DEBUG:-}" ] || set -x

. "$(librelib conf)"
. "$(librelib messages)"

list_builds() {
  local format="%-3s   %-20s   %-6s   %-8s   %-14s\n"
  printf "$format" "ID" "Package" "Arch" "State" "Times(r/u/s)"
  local snap=$(tsp | tail -n+2)

  local running=$(echo "$snap" | grep ' running ')
  [ -n "$running" ] && while read -r line; do
    printf "$format" $(echo "$line" | awk '{print $1, $(NF-1), $(NF), $2}') ""
  done <<< "$running"

  local queued=$(echo "$snap" | grep ' queued ')
  [ -n "$queued" ] && while read -r line; do
    printf "$format" $(echo "$line" | awk '{print $1, $(NF-1), $(NF), $2}') ""
  done <<< "$queued"

  local failed=$(echo "$snap" | grep ' finished ' | awk '$4 != "0" {print $0}')
  [ -n "$failed" ] && while read -r line; do
    printf "$format" $(echo "$line" | awk '{print $1, $(NF-1), $(NF), "failed", $5}')
  done <<< "$failed"

  local finished=$(echo "$snap" | grep ' finished ' | awk '$4 == "0" {print $0}')
  [ -n "$finished" ] && while read -r line; do
    printf "$format" $(echo "$line" | awk '{print $1, $(NF-1), $(NF), $2, $5}')
  done <<< "$finished"

  echo -n "running: $(echo -n "$running" | grep -c '^'), "
  echo -n "queued: $(echo -n "$queued" | grep -c '^'), "
  echo -n "failed: $(echo -n "$failed" | grep -c '^'), "
  echo    "finished: $(echo -n "$finished" | grep -c '^')"
}

enqueue_builds() {
  [ -f PKGBUILD ] || (error "missing PKGBUILD" && return $EXIT_FAILURE)
  local srcinfo=$(makepkg --printsrcinfo 2>&1) || return $EXIT_FAILURE
  local pkgname=( $(echo "$srcinfo" | grep 'pkgname = ' | awk '{print $3}') )
  [ -n "$pkgname" ] || (error "malformed PKGBUILD" && return $EXIT_FAILURE)

  local arches=()
  if [ $# -gt 0 ]; then
    arches+=( "$@" )
  else
    arches+=( $(echo "$srcinfo" | grep 'arch = ' | awk '{print $3}' \
        | sed "s@any@$(uname -m)@" | sort -r | uniq) )
    [ -n "${arches[0]}" ] || (error "malformed PKGBUILD" && return $EXIT_FAILURE)
  fi

  load_conf libretools.conf ARCHES
  arches=( $(comm -12 <(printf '%s\n' "${ARCHES[@]}" | sort -r) \
                      <(printf '%s\n' "${arches[@]}" | sort -r)) )

  local a
  for a in "${arches[@]}"; do
    local running=$(tsp | grep ' running ' | grep -q " x $pkgname $a")
    [ -z "$running" ] || error "cannot queue for $a: build is running"
    local id
    for id in $(tsp | grep -v ' running ' | grep " x $pkgname $a" | awk '{print $1}'); do
      tsp -r $id
    done
    tsp "$0" x $pkgname $a
  done
}

kill_build() {
  # FIXME: do better than this.
  tsp -k
}

clear_builds() {
  if [ $# -gt 0 ]; then
    local id
    for id in "$@"; do tsp -r $id; done
  else
    for id in $($0 | awk '$4 == "finished" {print $1}'); do
      tsp -r $id
    done
  fi
}

show_build() {
  if [ $# -gt 0 ]; then
    tsp -c $1
  else
    while tsp | grep -q ' running '; do tsp -c; done
  fi
}

notify() {
  if type -p notify-send >/dev/null; then
    notify-send -h string:recipient:-213551758 "$@"
  fi
}

build_error() {
  local a="${1//_/\\_}"
  notify -c error "*[Q$($0 | tail -n1 | awk '{print $4}' | tr -d ',')]* $a" -h string:document:$2
}

build_success() {
  local a="${1//_/\\_}"
  notify -c success "*[Q$($0 | tail -n1 | awk '{print $4}' | tr -d ',')]* $a"
}

prepare_chroot() {
  # clean the chroot
  sudo librechroot -A $1 -n qbu-$1 clean-pkgs && _clean=yes || _clean=no
  if [ "x$_clean" == "xno" ]; then
    sudo librechroot -A $1 -n qbu-$1 delete
    sudo librechroot -A $1 -n qbu-$1 -l root delete
    sudo librechroot -A $1 -n qbu-$1 make
    sudo librechroot -A $1 -n qbu-$1 clean-pkgs || return
  fi

  # update the chroot
  sudo librechroot -A $1 -n qbu-$1 update && _updated=yes || _updated=no
  if [ "x$_clean" == "xno" ]; then
    sudo librechroot -A $1 -n qbu-$1 delete
    sudo librechroot -A $1 -n qbu-$1 -l delete
    sudo librechroot -A $1 -n qbu-$1 make
    sudo librechroot -A $1 -n qbu-$1 update || return
  fi
}

run_build() {
  [ -f PKGBUILD ] || (error "missing PKGBUILD" && return $EXIT_FAILURE)

  out="$(mktemp)"
  prepare_chroot $2 2>&1 | tee "$out" || build_error "broken qbu-$2" "$out"
  rm "$out"
  out="$(mktemp)"
  set +e
  sudo libremakepkg -n qbu-$2 2>&1 | tee "$out"
  res=$?
  set -e
  [ $res -eq 0 ] && build_success "$1-$2" || build_error "$1-$2" "$out"
  rm "$out"
  return $res
}

case "${1:-l}" in
  l) list_builds "${@:2}" ;;
  q) enqueue_builds "${@:2}" ;;
  k) kill_build "${@:2}" ;;
  r) clear_builds "${@:2}" ;;
  c) show_build "${@:2}" ;;
  x) run_build "${@:2}" ;;
  *) error "$1: unrecognized command" && exit $EXIT_FAILURE ;;
esac





