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
    |> Pages.from_markdown
    |> Pages.wrap_html layout
    |> Pages.replace_html "page-list" page_list!

layout = \{ content, meta } ->
    Html.html {} [
        Html.head {} [
            Html.link { rel: "stylesheet", href: "/static/style.css" } [],
        ],
        Html.body {} [
            Html.h1 {} [Html.text meta.title],
            content,
        ],
    ]

page_list! = \{ attrs } ->
    posts = Pages.list! attrs.pattern
    Html.ul
        {}
        (
            List.map posts \post ->
                Html.li {} [
                    Html.a { href: post.path } [Html.text post.meta.title],
                ]
        )
