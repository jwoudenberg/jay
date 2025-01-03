#!/usr/bin/env roc
app [main] { pf: platform "../zig-out/platform/main.roc" }

import pf.Pages
import pf.Html

main = Pages.collect [
    Pages.files ["assets/*", "docs/*"],
    Pages.files ["index.md"]
    |> Pages.from_markdown
    |> Pages.wrap_html home_layout,
    Pages.files ["guide/*.md", "guide/*/*.md"]
    |> Pages.from_markdown
    |> Pages.wrap_html guide_layout!,
]

guide_layout! : { content : Html.Html, path : Str, meta : { title : Str } } => Html.Html
guide_layout! = \current_page ->
    Page : {
        title : Str,
        path : Str,
        order : U16,
        section : [SectionRoot Str, SectionSub Str],
    }

    Section : {
        key : Str,
        root_page : Page,
        sub_pages : List Page,
    }

    to_page : { path : Str, meta : { title : Str, order : U16 } } -> Page
    to_page = \{ path, meta: { title, order } } ->
        when Str.splitOn path "/" is
            ["", "guide"] ->
                {
                    title,
                    path,
                    order,
                    section: SectionRoot "index",
                }

            ["", "guide", section] ->
                {
                    title,
                    path,
                    order,
                    section: SectionRoot section,
                }

            ["", "guide", section, "index.md"] ->
                {
                    title,
                    path,
                    order,
                    section: SectionRoot section,
                }

            ["", "guide", section, _] ->
                {
                    title,
                    path,
                    order,
                    section: SectionSub section,
                }

            _ -> crash "Unexpected guide path '$(path)'"

    pages : List Page
    pages =
        Pages.list! "guide/*.md"
        |> List.concat (Pages.list! "guide/*/*.md")
        |> List.map to_page

    empty_sections : Dict Str Section
    empty_sections = List.walk pages (Dict.empty {}) \acc, page ->
        when page.section is
            SectionRoot key ->
                Dict.insert acc key {
                    key,
                    root_page: page,
                    sub_pages: [],
                }

            SectionSub _ -> acc

    sections : Dict Str Section
    sections = List.walk pages empty_sections \acc, page ->
        when page.section is
            SectionRoot _ -> acc
            SectionSub key ->
                Dict.update acc key \result ->
                    when result is
                        Err Missing -> crash "No root section for $(key)"
                        Ok section ->
                            Ok
                                { section &
                                    sub_pages: section.sub_pages
                                    |> List.append page
                                    |> List.sortWith \a, b -> Num.compare a.order b.order,
                                }

    link_sections =
        Dict.values sections
        |> List.sortWith \a, b -> Num.compare a.root_page.order b.root_page.order
        |> List.map \section ->
            links =
                List.concat
                    [link section.root_page]
                    (List.map section.sub_pages link)
            Html.li {} [Html.ul { class: "section-links" } links]

    link = \page -> Html.li
            { class: if page.path == current_page.path then "active" else "" }
            [Html.a { href: page.path } [Html.text page.title]]

    content = Html.div { class: "guide" } [
        Html.nav {} [Html.ul {} link_sections],
        Html.main {} [
            Html.h2 {} [Html.text current_page.meta.title],
            current_page.content,
        ],
    ]

    layout content

home_layout : { content : Html.Html, path : Str, meta : {} } -> Html.Html
home_layout = \current_page ->
    content = Html.main { class: "home" } [current_page.content]
    layout content

layout : Html.Html -> Html.Html
layout = \content ->
    link = \href, text -> Html.li {} [Html.a { href } [Html.text text]]
    Html.html {} [
        Html.head {} [
            Html.meta { charset: "utf-8" } [],
            Html.meta { name: "viewport", content: "width=device-width, initial-scale=1.0" } [],
            Html.link { rel: "stylesheet", href: "/assets/style.css" } [],
            Html.title {} [Html.text "Jay"],
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
