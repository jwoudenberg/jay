#!/usr/bin/env roc
app [main] { pf: platform "../zig-out/platform/main.roc" }

import pf.Pages
import pf.Html exposing [Html]

main = [
    static,
    pages,
    posts,
    Pages.ignore ["README.md"],
]

static = Pages.files ["/static"]

pages =
    Pages.files ["*.md"]
    |> Pages.fromMarkdown
    |> Pages.wrapHtml layout

posts =
    Pages.files ["/posts"]
    |> Pages.fromMarkdown
    |> Pages.wrapHtml layout

layout : Html -> Html
layout = \contents ->
    Html.html {} [
        Html.head {} [
            Html.link { href: "/static/main.css", rel: "stylesheet" } [],
        ],
        Html.body {} [contents],
    ]
