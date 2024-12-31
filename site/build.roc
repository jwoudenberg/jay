#!/usr/bin/env roc
app [main] { pf: platform "../zig-out/platform/main.roc" }

import pf.Pages
import pf.Html

main = Pages.collect [
    Pages.files ["assets/*", "docs/*"],
    Pages.files ["index.md"]
    |> Pages.from_markdown
    |> Pages.wrap_html home_layout,
    Pages.files ["guide/*.md"]
    |> Pages.from_markdown
    |> Pages.wrap_html guide_layout,
]

guide_layout = \{ content } ->
    home_content = Html.main { class: "guide" } [content]
    layout { content: home_content }

home_layout = \{ content } ->
    home_content = Html.main { class: "home" } [content]
    layout { content: home_content }

layout = \{ content } ->
    link = \href, text -> Html.li {} [Html.a { href } [Html.text text]]
    Html.html {} [
        Html.head {} [
            Html.meta { charset: "utf-8" } [],
            Html.meta { name: "viewport", content: "width=device-width, initial-scale=1.0" } [],
            Html.link { rel: "stylesheet", href: "/assets/style.css" } [],
        ],
        Html.body {} [
            Html.header { class: "header" } [
                Html.h1 {} [Html.a { href: "/" } [Html.text "Jay"]],
                Html.nav {} [
                    Html.ul {} [
                        link "/guide" "Guide",
                        link "/docs" "API Docs",
                        link "https://github.com/jwoudenberg/jay" "Contribute",
                    ],
                ],
            ],
            content,
        ],
    ]
