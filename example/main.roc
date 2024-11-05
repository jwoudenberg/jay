#!/usr/bin/env roc
app [main] { pf: platform "../zig-out/platform/main.roc" }

import pf.Pages
import pf.Html

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
    |> Pages.replaceHtml "page-list" postList
    |> Pages.wrapHtml layout

posts =
    Pages.files ["/posts"]
    |> Pages.fromMarkdown
    |> Pages.wrapHtml layout

layout = \{ content, path, meta } ->
    Html.html {} [
        Html.head {} [
            Html.title {} [Html.text "My Blog"],
            Html.link { href: "/static/main.css", rel: "stylesheet" } [],
        ],
        Html.body {} [
            Html.h1 {} [Html.text "My Blog"],
            Html.a { href: path } [Html.h2 {} [Html.text meta.title]],
            content,
        ],
    ]

postList = \{ attrs: { pattern } } ->
    Html.ul {} [
        Html.li {} [Html.text "TODO: show posts matching $(pattern) here"],
    ]
