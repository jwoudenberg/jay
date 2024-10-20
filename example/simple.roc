#!/usr/bin/env roc
app [main] { pf: platform "../zig-out/platform/main.roc" }

import pf.Site

main =
    Site.copy! (Site.files ["index.md", "about.md"])
    Site.copy! (Site.filesIn "/posts")
