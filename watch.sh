#!/usr/bin/env bash

set -exuo pipefail

git ls-files | exec entr -s 'zig build && ./example/simple.roc --linker=legacy'
