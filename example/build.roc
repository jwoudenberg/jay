#!/usr/bin/env roc
app [main] { pf: platform "../zig-out/platform/main.roc" }

import pf.Pages
import pf.Html

main =
    { Pages.rules <-
        markdown,
        static: Pages.files ["static/*.css"],
        ignore: Pages.ignore ["README.md"],
    }

markdown =
    Pages.files ["*.md", "posts/*.md"]
    |> Pages.fromMarkdown
    |> Pages.wrapHtml layout
    |> Pages.replaceHtml "page-list" pageList!

layout = \{ content, meta } ->
    Html.html {} [
        Html.head {} [],
        Html.body {} [
            Html.h1 {} [Html.text meta.title],
            content,
        ],
    ]

pageList! = \{ attrs } ->
    posts = Pages.list! attrs.pattern
    Html.ul
        {}
        (
            List.map posts \post ->
                Html.li {} [
                    Html.a { href: post.path } [Html.text post.meta.title],
                ]
        )
