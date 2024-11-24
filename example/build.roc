#!/usr/bin/env roc
app [main] { pf: platform "../zig-out/platform/main.roc" }

import pf.Pages
import pf.Html

main = [
    markdownFiles,
    Pages.files ["static/*.css"],
    Pages.ignore [],
]

markdownFiles =
    Pages.files ["*.md", "posts/*.md"]
    |> Pages.fromMarkdown
    |> Pages.wrapHtml layout

layout = \{ content } ->
    Html.html {} [
        Html.head {} [],
        Html.body {} [content],
    ]
