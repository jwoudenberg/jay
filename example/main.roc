#!/usr/bin/env roc
app [main] { pf: platform "github.com/jwoudenberg/roc-static-site" }

import Site
import Html

main = \{} ->
    Site.copy! (Site.filesIn "static")

    posts = Site.fromMarkdown [] (Site.filesIn "posts")

    Site.wrapHtml posts applyLayout
        |> Site.copy!

    Site.files ["blog.html", "about.html"]
        |> Site.wrapHtml applyLayout
        |> Site.replaceHtml "posts-list" (\_ -> renderPostsListing posts)
        |> Site.copy!

renderPostsListing : Pages Html { title : Str } -> Site.Widget
renderPostsListing = \posts ->
    itemToHtml = \{ path, title } ->
        Html.li [] [
            Html.a [Html.attr "href" path] [Html.text title],
        ]

    items = List.map (Site.meta posts) itemToHtml

    Html.ul [] items

applyLayout : _, Site.Html -> Site.Html
applyLayout = \contents ->
    Html.html
        []
        [
            Html.head
                []
                [Html.link [Html.attr "href" "/static/main.css", Html.attr "rel" "stylesheet"] []],
            Html.body
                []
                [contents],
        ]
