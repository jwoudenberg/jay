module [
    Pages,
    bootstrap,
    rules,
    files,
    ignore,
    fromMarkdown,
    wrapHtml,
    replaceHtml,
    list!,
]

import Pages.Internal exposing [wrap, unwrap, Xml]
import Html exposing [Html]
import Xml.Internal
import Effect
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
        replaceTags: [],
        pipeline!: \content, _ -> content,
    },
]

rules : Pages a, Pages b, (a, b -> c) -> Pages c
rules = \pagesA, pagesB, _ ->
    List.concat (unwrap pagesA) (unwrap pagesB)
    |> wrap

files : List Str -> Pages type
files = \patterns ->
    wrap [
        {
            patterns,
            processing: None,
            replaceTags: [],
            pipeline!: \content, _ -> content,
        },
    ]

ignore : List Str -> Pages type
ignore = \patterns ->
    wrap [
        {
            patterns,
            processing: Ignore,
            replaceTags: [],
            pipeline!: \content, _ -> content,
        },
    ]

fromMarkdown : Pages Markdown -> Pages Html
fromMarkdown = \pages ->
    unwrap pages
    |> List.map \page -> { page & processing: Markdown }
    |> wrap

wrapHtml : Pages Html, ({ content : Html, path : Str, meta : {}a } => Html) -> Pages Html where a implements Decoding
wrapHtml = \pages, userWrapper! ->
    wrapper! : Xml, Pages.Internal.HostPage => Xml
    wrapper! = \content, page ->
        meta =
            when Decode.fromBytes page.meta Rvn.compact is
                Ok x -> x
                Err _ ->
                    when Str.fromUtf8 page.meta is
                        Ok str -> crash "@$%^&.jayerror*0*$(str)"
                        Err _ -> crash "frontmatter bytes not UTF8-encoded"

        userWrapper! { content: Xml.Internal.wrap content, path: page.path, meta }
        |> Xml.Internal.unwrap

    unwrap pages
    |> List.map \page -> {
        patterns: page.patterns,
        processing: if page.processing == None then Xml else page.processing,
        replaceTags: page.replaceTags,
        pipeline!: \content, hostPage ->
            page.pipeline! content hostPage
            |> wrapper! hostPage,
    }
    |> wrap

list! : Str => List { path : Str, meta : {}a }
list! = \pattern ->
    Effect.list! pattern
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
replaceHtml :
    Pages Html,
    Str,
    ({ content : Html, attrs : {}attrs, path : Str, meta : {}a } => Html)
    -> Pages Html
replaceHtml = \pages, name, userReplacer! ->
    replacer! : Xml, Pages.Internal.Page, Pages.Internal.HostPage => Xml
    replacer! = \original, page, hostPage ->
        meta =
            when Decode.fromBytes hostPage.meta Rvn.compact is
                Ok x -> x
                Err _ ->
                    when Str.fromUtf8 hostPage.meta is
                        Ok str -> crash "@$%^&.jayerror*0*$(str)"
                        Err _ -> crash "frontmatter bytes not UTF8-encoded"

        walk! hostPage.tags original \content, tag ->
            if Num.intCast tag.index == List.len page.replaceTags then
                attrs =
                    when Decode.fromBytes tag.attributes Xml.Attributes.formatter is
                        Ok x -> x
                        Err _ ->
                            when Str.fromUtf8 tag.attributes is
                                Ok str -> crash "@$%^&.jayerror*1*$(str)"
                                Err _ -> crash "attribute bytes not UTF8-encoded"

                replaceTag! content tag \nested ->
                    userReplacer! {
                        content: Xml.Internal.wrap nested,
                        path: hostPage.path,
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
        replaceTags: List.append page.replaceTags name,
        pipeline!: \content, hostPage ->
            page.pipeline! content hostPage
            |> replacer! page hostPage,
    }
    |> wrap

replaceTag! : Xml, Pages.Internal.HostTag, (Xml => Xml) => Xml
replaceTag! = \content, tag, replace! ->
    { before, nested, after } = replaceTagHelper content tag
    before
    |> List.concat (replace! nested)
    |> List.concat after

replaceTagHelper : Xml, Pages.Internal.HostTag -> { before : Xml, nested : Xml, after : Xml }
replaceTagHelper = \content, tag ->
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

# A pure version of replaceTag! that shares almost all the logic, for testing.
replaceTag : Xml, Pages.Internal.HostTag, (Xml -> Xml) -> Xml
replaceTag = \content, tag, replace ->
    { before, nested, after } = replaceTagHelper content tag
    before
    |> List.concat (replace nested)
    |> List.concat after

parseTagForTest : List U8 -> Pages.Internal.HostTag
parseTagForTest = \bytes ->
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
markForTest : Xml -> Xml
markForTest = \xml ->
    List.map xml \slice ->
        when slice is
            FromSource { start, end } -> FromSource { start: 1000 + start, end: 1000 + end }
            RocGenerated bytes -> RocGenerated (['!'] |> List.concat bytes |> List.append '!')

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice:  []
    tag = parseTagForTest content
    actual =
        [FromSource { start: 0, end: 2 }]
        |> replaceTag tag markForTest
    [FromSource { start: 0, end: 2 }]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice: [    ]
    tag = parseTagForTest content
    actual =
        [FromSource { start: 0, end: 6 }]
        |> replaceTag tag markForTest
    [
        FromSource { start: 0, end: 4 },
        FromSource { start: 1009, end: 1009 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice: [        ]
    tag = parseTagForTest content
    actual =
        [FromSource { start: 0, end: 10 }]
        |> replaceTag tag markForTest
    [
        FromSource { start: 0, end: 4 },
        FromSource { start: 1009, end: 1010 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice: [            ]
    tag = parseTagForTest content
    actual =
        [FromSource { start: 0, end: 14 }]
        |> replaceTag tag markForTest
    [
        FromSource { start: 0, end: 4 },
        FromSource { start: 1009, end: 1011 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice: [                  ]
    tag = parseTagForTest content
    actual =
        [FromSource { start: 0, end: 20 }]
        |> replaceTag tag markForTest
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
    tag = parseTagForTest content
    actual =
        [FromSource { start: 6, end: 20 }]
        |> replaceTag tag markForTest
    [
        FromSource { start: 1009, end: 1011 },
        FromSource { start: 17, end: 20 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice:           [        ]
    tag = parseTagForTest content
    actual =
        [FromSource { start: 10, end: 20 }]
        |> replaceTag tag markForTest
    [
        FromSource { start: 1010, end: 1011 },
        FromSource { start: 17, end: 20 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice:               [    ]
    tag = parseTagForTest content
    actual =
        [FromSource { start: 14, end: 20 }]
        |> replaceTag tag markForTest
    [
        FromSource { start: 1011, end: 1011 },
        FromSource { start: 17, end: 20 },
    ]
    == actual

expect
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice:                   []
    tag = parseTagForTest content
    actual =
        [FromSource { start: 18, end: 20 }]
        |> replaceTag tag markForTest
    [
        FromSource { start: 18, end: 20 },
    ]
    == actual

expect
    # Generated content before the tag is not included in replaced contents.
    content = Str.toUtf8 "    <tag>hi</tag>   "
    #              index:  123456789 123456789
    #              slice: [ ]X
    tag = parseTagForTest content
    actual =
        [FromSource { start: 0, end: 3 }, RocGenerated ['X']]
        |> replaceTag tag markForTest
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
    tag = parseTagForTest content
    actual =
        [FromSource { start: 0, end: 10 }, RocGenerated ['X']]
        |> replaceTag tag markForTest
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
    tag = parseTagForTest content
    actual =
        [FromSource { start: 0, end: 17 }, RocGenerated ['X']]
        |> replaceTag tag markForTest
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
