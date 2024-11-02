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
import Xml.Internal
import Xml.Attributes
import Rvn

Markdown := {}

Metadata : PagesInternal.Metadata

Pages a : PagesInternal.Pages a

# Parse directory structure and rewrite main.roc with initial implementation.
bootstrap : List (Pages type)
bootstrap = [
    wrap \_ -> {
        patterns: [],
        processing: Bootstrap,
        pages: [],
        replaceTags: [],
    },
]

files : List Str -> Pages type
files = \patterns ->
    wrap \meta -> {
        patterns,
        processing: None,
        replaceTags: [],
        pages: List.map meta \_ -> [FromSource 0],
    }

ignore : List Str -> Pages type
ignore = \patterns ->
    wrap \_ -> { patterns, processing: Ignore, pages: [], replaceTags: [] }

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
                |> Xml.Internal.wrap
                |> htmlWrapper { path, metadata }
                |> Xml.Internal.unwrap,
        }

# Replace an HTML element in the passed in pages.
replaceHtml :
    Pages Html,
    Str,
    ({ content : Html, attributes : {}attrs, path : Str, metadata : {}a } -> Html)
    -> Pages Html
replaceHtml = \pages, tag, replaceTag ->
    wrap \meta ->
        internal = (unwrap pages) meta
        replacerIndex = List.len internal.replaceTags
        { internal &
            replaceTags: List.append internal.replaceTags tag,
            pages: List.map2 internal.pages meta \page, { path, frontmatter, replacements } ->
                metadata =
                    when Decode.fromBytes frontmatter Rvn.compact is
                        Ok x -> x
                        Err _ ->
                            when Str.fromUtf8 frontmatter is
                                Ok str -> crash "@$%^&.jayerror*0*$(str)"
                                Err _ -> crash "frontmatter bytes not UTF8-encoded"

                matches =
                    when List.get replacements replacerIndex is
                        Ok x -> x
                        Err OutOfBounds -> crash "@$%^&.jayerror*z*replacers shorter than expected"

                List.walk page { acc: [], matchIndex: 0 } \{ acc, matchIndex }, slice ->
                    when slice is
                        FromSource index if index == replacerIndex ->
                            attributeBytes =
                                when List.get matches matchIndex is
                                    Ok x -> x
                                    Err OutOfBounds -> crash "@$%^&.jayerror*z*replacements shorter than expected"
                            attributes =
                                when Decode.fromBytes attributeBytes Xml.Attributes.formatter is
                                    Ok x -> x
                                    Err _ -> crash "@$%^&.jayerror*z*failed decoding attributes"

                            content = Xml.Internal.wrap [slice]

                            replacement = replaceTag { content, path, attributes, metadata }

                            {
                                matchIndex: matchIndex + 1,
                                acc: List.concat acc (Xml.Internal.unwrap replacement),
                            }

                        _ -> { acc: List.append acc slice, matchIndex } # TODO: check matchIndex equals replacements length
                |> .acc,
        }

# Advanced: Used to implement functions like 'fromMarkdown'
toHtml :
    {
        extension : Str,
        parser : List U8 -> (Html, {}meta),
    },
    Pages type
    -> Pages Html
