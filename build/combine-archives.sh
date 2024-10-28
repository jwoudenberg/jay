#!/usr/bin/env bash

set -euo pipefail

# Approach to combining .a files from the following stack overflow:
# https://stackoverflow.com/questions/3821916/how-to-merge-two-ar-static-libraries-into-one

ar cqT "combined.a" "${@:2}"
echo -e 'create combined.a\naddlib combined.a\nsave\nend' | ar -M
mv "combined.a" "$1"
