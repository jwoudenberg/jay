module [
    Pages,
    Metadata,
    bootstrap,
    files,
    ignore,
    fromMarkdown,
    wrapHtml,
    replaceHtml,
    toHtml,
]

import PagesInternal exposing [wrap, unwrap]
import Html exposing [Html]
import XmlInternal

Markdown := {}

Metadata : PagesInternal.Metadata

Pages a : PagesInternal.Pages a

# Parse directory structure and rewrite main.roc with initial implementation.
bootstrap : List (Pages type)
bootstrap = [wrap \_ -> { patterns: [], processing: Bootstrap, content: [] }]

files : List Str -> Pages type
files = \patterns -> wrap \_ -> { patterns, processing: None, content: [SourceFile] }

ignore : List Str -> Pages type
ignore = \patterns ->
    wrap \_ -> { patterns, processing: Ignore, content: [] }

fromMarkdown : Pages Markdown -> Pages Html
fromMarkdown = \pages ->
    wrap \req ->
        internal = (unwrap pages) req
        { internal & processing: Markdown }

wrapHtml : Pages Html, (Html -> Html) -> Pages Html
wrapHtml = \pages, htmlWrapper ->
    wrap \req ->
        internal = (unwrap pages) req
        when req is
            PatternsOnly -> internal
            Content _meta ->
                { internal &
                    content: internal.content
                    |> XmlInternal.wrap
                    |> htmlWrapper
                    |> XmlInternal.unwrap,
                }

# Replace an HTML element in the passed in pages.
replaceHtml : Pages Html, Str, ({}attrs, Html -> Html) -> Pages Html

# Advanced: Used to implement functions like 'fromMarkdown'
toHtml :
    {
        extension : Str,
        parser : List U8 -> (Html, {}meta),
    },
    Pages type
    -> Pages Html
