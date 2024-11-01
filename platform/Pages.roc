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
import Rvn

Markdown := {}

Metadata : PagesInternal.Metadata

Pages a : PagesInternal.Pages a

# Parse directory structure and rewrite main.roc with initial implementation.
bootstrap : List (Pages type)
bootstrap = [wrap \_ -> { patterns: [], processing: Bootstrap, pages: [] }]

files : List Str -> Pages type
files = \patterns ->
    wrap \meta -> {
        patterns,
        processing: None,
        pages: List.map meta \_ -> [SourceFile],
    }

ignore : List Str -> Pages type
ignore = \patterns ->
    wrap \_ -> { patterns, processing: Ignore, pages: [] }

fromMarkdown : Pages Markdown -> Pages Html
fromMarkdown = \pages ->
    wrap \meta ->
        internal = (unwrap pages) meta
        { internal & processing: Markdown }

wrapHtml : Pages Html, (Html, { path : Str, metadata : {}a } -> Html) -> Pages Html where a implements Decoding
wrapHtml = \pages, htmlWrapper ->
    wrap \meta ->
        internal = (unwrap pages) meta
        { internal &
            pages: List.map2 internal.pages meta \page, { path, frontmatter } ->
                metadata =
                    when Decode.fromBytes frontmatter Rvn.compact is
                        Ok x -> x
                        Err _ ->
                            when Str.fromUtf8 frontmatter is
                                Ok str -> crash "@$%^&.jayerror*0*$(str)"
                                Err _ -> crash "frontmatter bytes not UTF8-encoded"
                page
                |> XmlInternal.wrap
                |> htmlWrapper { path, metadata }
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
