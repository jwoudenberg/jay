#!/usr/bin/env roc
app [main] { pf: platform "../zig-out/platform/main.roc" }

import pf.Site

main =
    Site.match { dirs: ["/static"] }
        |> Site.copy!
    Site.match { dirs: ["posts"], files: ["index.md", "about.md"] }
        |> Site.fromMarkdown
        |> Site.copy!
