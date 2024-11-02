#!/usr/bin/env bash

set -exuo pipefail

jj file list | exec entr -cs 'roc test platform/main.roc && zig build && zig build test && ./example/main.roc --linker=legacy'
