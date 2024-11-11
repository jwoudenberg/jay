#!/usr/bin/env bash

set -exuo pipefail

jj file list | exec entr -csr 'roc test platform/main.roc && zig build && zig build test && ./example/build.roc --linker=legacy'
