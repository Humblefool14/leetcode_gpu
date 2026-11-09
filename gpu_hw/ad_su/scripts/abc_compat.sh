#!/usr/bin/env bash
# Adapts the ABC command line of a newer SymbiYosys to the older system yosys-abc
# (whose pdr lacks -l).  Usage is transparent: sby --abc scripts/abc_compat.sh
args=()
for a in "$@"; do args+=("${a//pdr -v -l/pdr -v}"); done
exec yosys-abc "${args[@]}"
