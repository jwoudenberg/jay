#!/usr/bin/env roc
app [main] { pf: platform "../zig-out/platform/main.roc" }

import pf.Site
import pf.Html exposing [Html]

main =
    Site.files ["/static"]
        |> Site.copy!

    Site.files ["*.md"]
        |> Site.fromMarkdown
        |> Site.wrapHtml pageLayout
        |> Site.copy!

    Site.files ["/posts"]
        |> Site.fromMarkdown
        |> Site.wrapHtml pageLayout
        |> Site.copy!

    Site.ignore! ["README.md"]

pageLayout : Html -> Html
pageLayout = \contents ->
    Html.html {} [
        Html.head {} [
            Html.link { href: "/static/main.css", rel: "stylesheet" } [],
        ],
        Html.body {} [contents],
    ]
