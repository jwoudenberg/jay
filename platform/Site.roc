module [
    Pages,
    bootstrap,
    copy,
    files,
    ignore,
    fromMarkdown,
    wrapHtml,
    replaceHtml,
    toHtml,
]

import Effect
import Html exposing [Html]
import XmlInternal

Markdown := {}

Pages a := Effect.Pages

copy : Pages content -> Task {} *
copy = \@Pages pages ->
    Task.attempt
        (Effect.copy (Box.box pages))
        (\result ->
            when result is
                Ok {} -> Task.ok {}
                Err _ -> crash "OH NOES"
        )

# Parse directory structure and rewrite main.roc with initial implementation.
bootstrap : Task {} []

files : List Str -> Pages content
files = \patterns -> @Pages { patterns, processing: None, wrapper: [SourceFile] }

ignore : List Str -> Task {} *
ignore = \patterns ->
    @Pages { patterns, processing: Ignore, wrapper: [] }
    |> copy

fromMarkdown : Pages Markdown -> Pages Html
fromMarkdown = \@Pages pages -> @Pages { pages & processing: Markdown }

wrapHtml : Pages Html, (Html -> Html) -> Pages Html
wrapHtml = \@Pages pages, wrap ->
    @Pages
        { pages &
            wrapper: pages.wrapper |> XmlInternal.wrap |> wrap |> XmlInternal.unwrap,
        }

# Replace an HTML element in the passed in pages.
replaceHtml : Pages Html, Str, ({}attrs, Html -> Html) -> Pages Html

# Advanced: Used to implement functions like 'fromMarkdown'
toHtml :
    {
        extension : Str,
        parser : List U8 -> (Html, {}meta),
    },
    Pages content
    -> Pages Html
