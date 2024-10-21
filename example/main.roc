#!/usr/bin/env roc
app [main] { pf: platform "../zig-out/platform/main.roc" }

import pf.Site exposing [Pages, Html]
import pf.Html

main =
    Site.match { dirs: ["static"] }
        |> Site.copy!

    posts = Site.match { dirs: ["posts"] } |> Site.fromMarkdown

    Site.wrapHtml posts applyLayout
        |> Site.copy!

    Site.match { files: ["blog.html", "about.html"] }
        |> Site.wrapHtml applyLayout
        |> Site.replaceHtml "posts-list" (\_ -> renderPostsListing posts)
        |> Site.copy!

renderPostsListing : Pages Html -> Html
renderPostsListing = \posts ->
    itemToHtml = \{ path, title } ->
        Html.li [] [
            Html.a [Html.attr "href" path] [Html.text title],
        ]

    items = List.map (Site.meta posts) itemToHtml

    Html.ul [] items

applyLayout : Html, _ -> Html
applyLayout = \contents, _ ->
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
