module [
    Pages,
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

Pages a : PagesInternal.Pages a

# Parse directory structure and rewrite main.roc with initial implementation.
bootstrap : List (Pages type)
bootstrap = [wrap { patterns: [], processing: Bootstrap, content: [] }]

files : List Str -> Pages type
files = \patterns -> wrap { patterns, processing: None, content: [SourceFile] }

ignore : List Str -> Pages type
ignore = \patterns ->
    wrap { patterns, processing: Ignore, content: [] }

fromMarkdown : Pages Markdown -> Pages Html
fromMarkdown = \pages ->
    internal = unwrap pages
    wrap { internal & processing: Markdown }

wrapHtml : Pages Html, (Html -> Html) -> Pages Html
wrapHtml = \pages, htmlWrapper ->
    internal = unwrap pages
    wrap
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
