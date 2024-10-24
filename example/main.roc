#!/usr/bin/env roc
app [main] { pf: platform "../zig-out/platform/main.roc" }

import pf.Site

main =
    Site.files ["/static"]
        |> Site.copy!

    Site.files ["/posts", "*.md"]
        |> Site.fromMarkdown
        |> Site.copy!

    Site.ignore! ["README.md"]
