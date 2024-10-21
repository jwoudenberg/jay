#!/usr/bin/env roc
app [main] { pf: platform "../zig-out/platform/main.roc" }

import pf.Site

main =
    Site.match { dirs: ["/posts"] }
        |> Site.copy!
    Site.match { files: ["index.md", "about.md"] }
        |> Site.copy!
