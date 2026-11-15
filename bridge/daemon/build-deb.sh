#!/bin/bash
# 出 Dopamine / rootless 用的 deb
set -e
export THEOS=${THEOS:-$HOME/theos}
cd "$(dirname "$0")"
make clean >/dev/null 2>&1 || true
make package FINALPACKAGE=1
echo "产物：$(pwd)/packages/"
ls -l packages/