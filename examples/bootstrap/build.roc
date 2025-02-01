#!/usr/bin/env roc
app [main] { pf: platform "../../zig-out/platform/main.roc" }

import pf.Pages

main = Pages.bootstrap
