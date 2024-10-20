#!/usr/bin/env bash

set -exuo pipefail

git ls-files | exec entr -s 'zig build && zig build test && ./example/simple.roc --linker=legacy'
