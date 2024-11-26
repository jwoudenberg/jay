#!/usr/bin/env bash

set -exuo pipefail

jj file list | exec entr -csr 'roc test platform/main.roc && zig build --prominent-compile-errors && zig build test --prominent-compile-errors'
