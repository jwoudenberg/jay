module [
    Pages,
    bootstrap,
    rules,
    files,
    ignore,
    from_markdown,
    wrap_html,
    replace_html,
    list!,
]

import Pages.Internal exposing [wrap, unwrap, Xml]
import Html exposing [Html]
import Xml.Internal
import Host
import Xml.Attributes
import Rvn

Markdown := {}

Pages a : Pages.Internal.Pages a

Bootstrap := {}

# Parse directory structure and rewrite build.roc with initial implementation.
bootstrap : Pages Bootstrap
bootstrap = wrap [
    {
        patterns: [],
        processing: Bootstrap,
        replace_tags: [],
        pipeline!: \content, _ -> content,
    },
]

rules : Pages a, Pages b, (a, b -> c) -> Pages c
rules = \pages_a, pages_b, _ ->
    List.concat (unwrap pages_a) (unwrap pages_b)
    |> wrap

files : List Str -> Pages type
files = \patterns ->
    wrap [
        {
            patterns,
            processing: None,
            replace_tags: [],
            pipeline!: \content, _ -> content,
        },
    ]

ignore : List Str -> Pages type
ignore = \patterns ->
    wrap [
        {
            patterns,
            processing: Ignore,
            replace_tags: [],
            pipeline!: \content, _ -> content,
        },
    ]

from_markdown : Pages Markdown -> Pages Html
from_markdown = \pages ->
    unwrap pages
    |> List.map \page -> { page & processing: Markdown }
    |> wrap

wrap_html : Pages Html, ({ content : Html, path : Str, meta : {}a } => Html) -> Pages Html where a implements Decoding
wrap_html = \pages, user_wrapper! ->
    wrapper! : Xml, Pages.Internal.HostPage => Xml
    wrapper! = \content, page ->
        meta =
            when Decode.fromBytes page.meta Rvn.compact is
                Ok x -> x
                Err _ ->
                    when Str.fromUtf8 page.meta is
                        Ok str -> crash "@$%^&.jayerror*0*$(str)"
                        Err _ -> crash "frontmatter bytes not UTF8-encoded"

        user_wrapper! { content: Xml.Internal.wrap content, path: page.path, meta }
        |> Xml.Internal.unwrap

    unwrap pages
    |> List.map \page -> {
        patterns: page.patterns,
        processing: if page.processing == None then Xml else page.processing,
        replace_tags: page.replace_tags,
        pipeline!: \content, host_page ->
            page.pipeline! content host_page
            |> wrapper! host_page,
    }
    |> wrap

list! : Str => List { path : Str, meta : {}a }
list! = \pattern ->
    Host.list! pattern
    |> List.map \result ->
        meta =
            when Decode.fromBytes result.meta Rvn.compact is
                Ok x -> x
                Err _ ->
                    when Str.fromUtf8 result.meta is
                        Ok str -> crash "@$%^&.jayerror*0*$(str)"
                        Err _ -> crash "frontmatter bytes not UTF8-encoded"
        { path: result.path, meta }

# Replace an HTML element in the passed in pages.
replace_html :
    Pages Html,
    Str,
    ({ content : Html, attrs : {}attrs, path : Str, meta : {}a } => Html)
    -> Pages Html
replace_html = \pages, name, user_replacer! ->
    replacer! : Xml, Pages.Internal.Page, Pages.Internal.HostPage => Xml
    replacer! = \original, page, host_page ->
        meta =
            when Decode.fromBytes host_page.meta Rvn.compact is
                Ok x -> x
                Err _ ->
                    when Str.fromUtf8 host_page.meta is
                        Ok str -> crash "@$%^&.jayerror*0*$(str)"
                        Err _ -> crash "frontmatter bytes not UTF8-encoded"

        walk! host_page.tags original \content, tag ->
            if Num.intCast tag.index == List.len page.replace_tags then
                attrs =
                    when Decode.fromBytes tag.attributes Xml.Attributes.formatter is
                        Ok x -> x
                        Err _ ->
                            when Str.fromUtf8 tag.attributes is
                                Ok str -> crash "@$%^&.jayerror*1*$(str)"
                                Err _ -> crash "attribute bytes not UTF8-encoded"

                replace_tag! content tag \nested ->
                    user_replacer! {
                        content: Xml.Internal.wrap nested,
                        path: host_page.path,
                        attrs,
                        meta,
                    }
                    |> Xml.Internal.unwrap
            else
                original

    unwrap pages
    |> List.map \page -> {
        patterns: page.patterns,
        processing: if page.processing == None then Xml else page.processing,
        replace_tags: List.append page.replace_tags name,
        pipeline!: \content, host_page ->
            page.pipeline! content host_page
            |> replacer! page host_page,
    }
    |> wrap

replace_tag! : Xml, Pages.Internal.HostTag, (Xml => Xml) => Xml
replace_tag! = \content, tag, replace! ->
    { before, nested, after } = replace_tag_helper content tag
    before
    |> List.concat (replace! nested)
    |> List.concat after

replace_tag_helper : Xml, Pages.Internal.HostTag -> { before : Xml, nested : Xml, after : Xml }
replace_tag_helper = \content, tag ->
    List.walk content { before: [], nested: [], after: [] } \acc, slice ->
        when slice is
            RocGenerated _ ->
                if !(List.isEmpty acc.after) then
                    { acc & after: List.append acc.after slice }
                else if !(List.isEmpty acc.nested) then
                    { acc & nested: List.append acc.nested slice }
                else
                    { acc & before: List.append acc.before slice }

            FromSource { start, end } ->
                if tag.outerEnd <= start then
                    # <tag /> [ slice ]
                    { acc & after: List.append acc.after slice }
                else if tag.outerStart >= end then
                    # [ slice ] <tag />
                    { acc & before: List.append acc.before slice }
                else if tag.outerStart <= start && tag.outerEnd >= end then
                    # <tag [ slice ] />
                    { acc &
                        nested: List.append
                            acc.nested
                            (
                                FromSource {
                                    start: clamp tag.innerStart start tag.innerEnd,
                                    end: clamp tag.innerStart end tag.innerEnd,
                                }
                            ),
                    }
                else if tag.outerStart < start && tag.outerEnd < end then
                    # <tag [ /> slice ]
                    { acc &
                        nested: List.append
                            acc.nested
                            (
                                FromSource {
                                    start: clamp tag.innerStart start tag.innerEnd,
                                    end: tag.innerEnd,
                                }
                            ),
                        after: List.append
                            acc.after
                            (FromSource { start: tag.outerEnd, end }),
                    }
                else if tag.outerStart > start && tag.outerEnd > end then
                    # [ slice <tag ] />
                    { acc &
                        before: List.append
                            acc.before
                            (FromSource { start, end: tag.outerStart }),
                        nested: List.append
                            acc.nested
                            (
                                FromSource {
                                    start: tag.innerStart,
                                    end: clamp tag.innerStart end tag.innerEnd,
                                }
                            ),
                    }
                else
                    # [ slice <tag /> ]
                    { acc &
                        before: List.append
                            acc.before
                            (FromSource { start, end: tag.outerStart }),
                        nested: List.append
                            acc.nested
                            (FromSource { start: tag.innerStart, end: tag.innerEnd }),
                        after: List.append
                            acc.after
                            (FromSource { start: tag.outerEnd, end }),
                    }

# A pure version of replace_tag! that shares almost all the logic, for testing.
replace_tag : Xml, Pages.Internal.HostTag, (Xml -> Xml) -> Xml
replace_tag = \content, tag, replace ->
    { before, nested, after } = replace_tag_helper content tag
    before
    |> List.concat (replace nested)
    |> List.concat after

parse_tag_for_test : List U8 -> Pages.Internal.HostTag
parse_tag_for_test = \bytes ->
    ok : Result (Int a) err -> Int b
    ok = \result ->
        when result is
            Ok x -> Num.intCast x
            Err _ -> crash "oops"

    {
        index: 0,
        outerStart: List.findFirstIndex bytes (\b -> b == '<') |> ok,
        outerEnd: 1 + (List.findLastIndex bytes (\b -> b == '>') |> ok),
        innerStart: 1 + (List.findFirstIndex bytes (\b -> b == '>') |> ok),
        innerEnd: List.findLastIndex bytes (\b -> b == '<') |> ok,
        attributes: [],
    }

# Mark some XML to make it recognizable in test output
mark_for_test : Xml -> Xml
mark_for_test = \xml ->
    List.map xml \slice ->
        when slice is
            FromSource { start, end } -> FromSource { start: 1000 + start, end: 1000 + end }
            RocGenerated bytes -> RocGenerated (['!'] |> List.concat bytes |> List.append '!')

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice:  []
    tag = parse_tag_for_test content
    actual =
        [FromSource { start: 0, end: 2 }]
        |> replace_tag tag mark_for_test
    [FromSource { start: 0, end: 2 }]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice: [    ]
    tag = parse_tag_for_test content
    actual =
        [FromSource { start: 0, end: 6 }]
        |> replace_tag tag mark_for_test
    [
        FromSource { start: 0, end: 4 },
        FromSource { start: 1009, end: 1009 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice: [        ]
    tag = parse_tag_for_test content
    actual =
        [FromSource { start: 0, end: 10 }]
        |> replace_tag tag mark_for_test
    [
        FromSource { start: 0, end: 4 },
        FromSource { start: 1009, end: 1010 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice: [            ]
    tag = parse_tag_for_test content
    actual =
        [FromSource { start: 0, end: 14 }]
        |> replace_tag tag mark_for_test
    [
        FromSource { start: 0, end: 4 },
        FromSource { start: 1009, end: 1011 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice: [                  ]
    tag = parse_tag_for_test content
    actual =
        [FromSource { start: 0, end: 20 }]
        |> replace_tag tag mark_for_test
    [
        FromSource { start: 0, end: 4 },
        FromSource { start: 1009, end: 1011 },
        FromSource { start: 17, end: 20 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice:       [            ]
    tag = parse_tag_for_test content
    actual =
        [FromSource { start: 6, end: 20 }]
        |> replace_tag tag mark_for_test
    [
        FromSource { start: 1009, end: 1011 },
        FromSource { start: 17, end: 20 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice:           [        ]
    tag = parse_tag_for_test content
    actual =
        [FromSource { start: 10, end: 20 }]
        |> replace_tag tag mark_for_test
    [
        FromSource { start: 1010, end: 1011 },
        FromSource { start: 17, end: 20 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice:               [    ]
    tag = parse_tag_for_test content
    actual =
        [FromSource { start: 14, end: 20 }]
        |> replace_tag tag mark_for_test
    [
        FromSource { start: 1011, end: 1011 },
        FromSource { start: 17, end: 20 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice:                   []
    tag = parse_tag_for_test content
    actual =
        [FromSource { start: 18, end: 20 }]
        |> replace_tag tag mark_for_test
    [
        FromSource { start: 18, end: 20 },
    ]
    == actual

expect
    # Generated content before the tag is not included in replaced contents.
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice: [ ]X
    tag = parse_tag_for_test content
    actual =
        [FromSource { start: 0, end: 3 }, RocGenerated ['X']]
        |> replace_tag tag mark_for_test
    [
        FromSource { start: 0, end: 3 },
        RocGenerated ['X'],
    ]
    == actual

expect
    # Generated content in the tag is included in replaced contents.
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice: [        ]X
    tag = parse_tag_for_test content
    actual =
        [FromSource { start: 0, end: 10 }, RocGenerated ['X']]
        |> replace_tag tag mark_for_test
    [
        FromSource { start: 0, end: 4 },
        FromSource { start: 1009, end: 1010 },
        RocGenerated ['!', 'X', '!'],
    ]
    == actual

expect
    # Generated content after the tag is not included in replaced contents.
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice: [               ]X
    tag = parse_tag_for_test content
    actual =
        [FromSource { start: 0, end: 17 }, RocGenerated ['X']]
        |> replace_tag tag mark_for_test
    [
        FromSource { start: 0, end: 4 },
        FromSource { start: 1009, end: 1011 },
        FromSource { start: 17, end: 17 },
        RocGenerated ['X'],
    ]
    == actual

clamp : Int a, Int a, Int a -> Int a
clamp = \lower, number, upper ->
    number
    |> Num.max lower
    |> Num.min upper

expect clamp 2 1 6 == 2
expect clamp 2 8 6 == 6
expect clamp 2 5 6 == 5
expect clamp 2 2 6 == 2
expect clamp 2 6 6 == 6

walk! :
    List elem,
    state,
    (state, elem => state)
    => state
walk! = \elems, state, fn! ->
    when elems is
        [] -> state
        [head, .. as rest] -> walk! rest (fn! state head) fn!
