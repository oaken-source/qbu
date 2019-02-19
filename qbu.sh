#!/bin/bash
###############################################################################
#       qbu -- (q)ueued (bu)ild manager for libretools                        #
#                                                                             #
#     Copyright (C) 2019  Andreas Grapentin                                   #
#                                                                             #
#     This program is free software: you can redistribute it and/or modify    #
#     it under the terms of the GNU General Public License as published by    #
#     the Free Software Foundation, either version 3 of the License, or       #
#     (at your option) any later version.                                     #
#                                                                             #
#     This program is distributed in the hope that it will be useful,         #
#     but WITHOUT ANY WARRANTY; without even the implied warranty of          #
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
#     GNU General Public License for more details.                            #
#                                                                             #
#     You should have received a copy of the GNU General Public License       #
#     along with this program.  If not, see <http://www.gnu.org/licenses/>.   #
###############################################################################

set -euo pipefail
[ -z "${DEBUG:-}" ] || set -x

. "$(librelib conf)"
. "$(librelib messages)"

list_builds() {
  local format="%-3s   %-40s   %-6s   %-8s   %-14s\n"
  printf "$format" "ID" "Package" "Arch" "State" "Times(r/u/s)"

  local snap
  snap=$(tsp | tail -n+2)

  local running queued failed finished

  running=$(echo "$snap" | grep ' running ')
  [ -n "$running" ] && while read -r line; do
    tput bold
    printf "$format" $(echo "$line" | awk '{print $1, $(NF-1), $(NF), $2}') ""
    tput sgr0
  done <<< "$running"

  queued=$(echo "$snap" | grep ' queued ')
  [ -n "$queued" ] && while read -r line; do
    printf "$format" $(echo "$line" | awk '{print $1, $(NF-1), $(NF), $2}') ""
  done <<< "$queued"

  failed=$(echo "$snap" | grep ' finished ' | awk '$4 != "0" {print $0}')
  [ -n "$failed" ] && while read -r line; do
    tput setf 1
    printf "$format" $(echo "$line" | awk '{print $1, $(NF-1), $(NF), "failed", $5}')
    tput sgr0
  done <<< "$failed"

  finished=$(echo "$snap" | grep ' finished ' | awk '$4 == "0" {print $0}')
  [ -n "$finished" ] && while read -r line; do
    tput setf 2
    printf "$format" $(echo "$line" | awk '{print $1, $(NF-1), $(NF), $2, $5}')
    tput sgr0
  done <<< "$finished"

  echo -n "running: $(echo -n "$running" | grep -c '^'), "
  echo -n "queued: $(echo -n "$queued" | grep -c '^'), "
  echo -n "failed: $(echo -n "$failed" | grep -c '^'), "
  echo    "finished: $(echo -n "$finished" | grep -c '^')"
}

enqueue_builds() {
  local pkglist pkgname running

  [ -f PKGBUILD ] || (error "missing PKGBUILD" && return "$EXIT_FAILURE")
  pkglist=$(makepkg --packagelist 2>&1) || return "$EXIT_FAILURE"
  pkgname=( $(echo "$pkglist" | rev | cut -d'-' -f2- | rev) )
  [ -n "${pkgname[0]}" ] || (error "malformed PKGBUILD" && return "$EXIT_FAILURE")

  local arches=()
  if [ $# -gt 0 ]; then
    arches+=( "$@" )
  else
    arches+=( $(echo "$pkglist" | rev | cut -d'-' -f1 | rev | cut -d'.' -f1 \
        | sed "s@any@$(uname -m)@" | sort -r | uniq) )
    [ -n "${arches[0]}" ] || (error "malformed PKGBUILD" && return "$EXIT_FAILURE")
  fi

  load_conf libretools.conf ARCHES
  arches=( $(comm -12 <(printf '%s\n' "${ARCHES[@]}" | sort) \
                      <(printf '%s\n' "${arches[@]}" | sort) | sort -r) )

  local a
  for a in "${arches[@]}"; do
    running=$(tsp | grep ' running ' | grep -q " x ${pkgname[0]} $a")
    [ -z "$running" ] || warning "${pkgname[0]}-$a: build is already running"
    local id
    for id in $(tsp | grep -v ' running ' | grep " x ${pkgname[0]} $a" | awk '{print $1}'); do
      tsp -r "$id"
    done
    tsp "$0" x "${pkgname[0]}" "$a"
  done
}

kill_build() {
  # FIXME: do better than this.
  tsp -k
}

clear_builds() {
  if [ $# -gt 0 ]; then
    local id
    for id in "$@"; do tsp -r "$id"; done
  else
    for id in $($0 | awk '$4 == "finished" {print $1}'); do
      tsp -r "$id"
    done
  fi
}

show_build() {
  if [ $# -gt 0 ]; then
    tsp -c "$1"
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
  notify -c error "*[Q$($0 | tail -n1 | awk '{print $4}' | tr -d ',')]* $a" -h "string:document:$2"
}

build_success() {
  local a="${1//_/\\_}"
  notify -c success "*[Q$($0 | tail -n1 | awk '{print $4}' | tr -d ',')]* $a"
}

prepare_chroot() {
  # clean the chroot
  sudo librechroot -A "$1" -n "qbu-$1" clean-pkgs && _clean=yes || _clean=no
  if [ "x$_clean" == "xno" ]; then
    sudo librechroot -A "$1" -n "qbu-$1" delete
    sudo librechroot -A "$1" -n "qbu-$1" -l root delete
    sudo librechroot -A "$1" -n "qbu-$1" make
    sudo librechroot -A "$1" -n "qbu-$1" clean-pkgs || return
  fi

  # update the chroot
  sudo librechroot -A "$1" -n "qbu-$1" update
  if [ "x$_clean" == "xno" ]; then
    sudo librechroot -A "$1" -n "qbu-$1" delete
    sudo librechroot -A "$1" -n "qbu-$1" -l delete
    sudo librechroot -A "$1" -n "qbu-$1" make
    sudo librechroot -A "$1" -n "qbu-$1" update || return
  fi

  # clean the chroot pkg cache
  sudo librechroot -A "$1" -n "qbu-$1" run \
    find /var/cache/pacman/pkg -type f -delete
}

run_build() {
  [ -f PKGBUILD ] || (error "missing PKGBUILD" && return "$EXIT_FAILURE")

  out="$(mktemp)"
  prepare_chroot "$2" 2>&1 | tee "$out" || build_error "broken qbu-$2" "$out"
  rm "$out"
  out="$(mktemp)"
  set +e
  sudo libremakepkg -n "qbu-$2" 2>&1 | tee "$out"
  res=$?
  set -e

  if [ $res -eq 0 ]; then
    build_success "$1-$2"
  else
    build_error "$1-$2" "$out"
  fi

  rm "$out"
  return $res
}

case "${1:-l}" in
  l)
    list_builds "${@:2}" ;;
  q)
    enqueue_builds "${@:2}" ;;
  k)
    kill_build "${@:2}" ;;
  r)
    clear_builds "${@:2}" ;;
  c)
    show_build "${@:2}" ;;
  x)
    run_build "${@:2}" ;;
  *)
    error "$1: unrecognized command"
    exit "$EXIT_FAILURE" ;;
esac
