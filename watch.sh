#!/usr/bin/env bash

set -exuo pipefail

git ls-files | exec entr -cs 'zig build && zig build test && ./example/main.roc --linker=legacy'
