## Jay proccesses all the files in a project directory to build a site.
##
## For example, below on the left are the files of a simple blog.
## On the right are the pages Jay will create for these files.
##
## ```
## index.md           => /index.html
## blog.md            => /blog.html
## posts/
##   a-great-day.md   => /posts/a-great-day.html
## static/
##   image.jpg        => /static/image.jpg
##   style.css        => /static/style.css
## README.md
## build.roc
## ```
##
## The `build.roc` file describes the processing Jay needs to perform for every
## source file in the project. The following `build.roc` would produce the
## example blog above:
##
## ```
## #!/usr/bin/env roc
## app [main] { pf: platform "github.com/jwoudenberg/roc-static-site" }
##
## main = Pages.collect [
##     files ["*.md", "posts/*.md"] |> from_markdown,
##     files ["static/*"],
##     ignore ["README.md"],
## ]
## ```
##
## Output files always have the same relative path as the source files they
## were created from. A markdown source file `posts/2024/trying-jay.md` will
## always produce an output path `/posts/2024/trying-jay.html`. Jay offers no
## way to override this.
##
## Jay can generate an initial `build.roc` file for you. Find the details in
## the documentation for the `bootstrap` function below.
##
## Once you have a `build.roc` file you can run it as a script:
##
## ```
## ./build.roc --linker=legacy
## ```
##
## This will start Jay in development mode. It will serve a preview of your
## site and automatically rebuild it when you make changes to source files.
##
## To publish the site you can run a production build:
##
## ```
## ./build.roc --linker=legacy prod output/
## ```
##
## This command will generate site files in the `output/` directory, then exit.
##
module [
    # page creation
    Pages,
    bootstrap,
    files,
    ignore,
    collect,

    # page rocessing
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

## Instructions for building the pages of a website. This includes actual pages
## such as an 'about' page or blog posts, but also assets like pictures and
## stylesheets.
Pages a : Pages.Internal.Pages a

## Helper for generating a first Jay configuration, if you don't have one yet.
## At the root of the project directory create a build.roc file, with these
## contents:
##
## ```
## #!/usr/bin/env roc
## app [main] { pf: platform "github.com/jwoudenberg/roc-static-site" }
##
## import pf.Pages
##
## main = Pages.bootstrap
## ```
##
## Now run the file with `./build.roc`. Jay will rewrite the file with an
## initial configuration based on the source files in the project directory.
bootstrap : Pages [Bootstrap]
bootstrap = wrap [
    {
        patterns: [],
        processing: Bootstrap,
        replace_tags: [],
        pipeline!: \content, _ -> content,
    },
]

## Combine rules for different types of pages into one value representing the
## entire site.
##
## Typically sites call this once in the `main` function.
##
## ```
## main = collect [
##     Pages.ignore ["README.md"],
##     Pages.files ["assets/*"],
## ]
##
## ```
collect : List (Pages a) -> Pages a
collect = \rules ->
    List.walk rules [] (\acc, rule -> List.concat acc (unwrap rule))
    |> wrap

## Takes a list of patterns, and adds all the source files matching one of the
## patterns to your site as a page.
##
## ```
## photos = files ["photos/*.jpg"]
## ```
##
## Combine `files` with other functions for source files requiring processing:
##
## ```
## posts =
##     files ["posts/*.md"]
##     |> from_markdown
## ```
##
## Patterns may contain multiple '*' globs matching part of a filename.
## '**' globs are not supported.
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

## Similar to `files`, `ignore` takes a list of patterns. Jay will ignore
## source files matching these patterns and not generate output files for them.
##
## ```
## main = Pages.collect [
##     Pages.files ["assets/*"],
##     Pages.ignore ["README.md", ".git"],
## ]
## ```
ignore : List Str -> Pages [Ignored]
ignore = \patterns ->
    wrap [
        {
            patterns,
            processing: Ignore,
            replace_tags: [],
            pipeline!: \content, _ -> content,
        },
    ]

## Process markdown source files, converting them to HTML files.
##
## ```
## posts =
##     files ["posts/*.md"]
##     |> from_markdown
## ```
##
## This function does not generate any `html` or `body` tags, only the
## HTML tags for the markdown formatting in the source files. You can use
## `wrap_html` to define a page layout.
##
##
## ### Frontmatter
##
## You can optionally add a frontmatter at the start of your markdown files.
##
## ```
## {
##   title: "A blog post about Roc",
## }
## ```
##
## The frontmatter needs to be a Roc record. Record fields may contain
## arbitrary Roc values. Check out the documentation for [Raven][1] to see
## what's supported.
##
##
## ### Syntax Highlighting
##
## Jay will add syntax highlighting for fenced code blocks. Jay currently has
## support for the languages Roc, Elm, Rust, and Zig, with more planned. If you
## need highlight support for a particular language, feel free to create an
## issue on the Jay Github repo!
##
## Syntax highlighting will generate `span` elements in the generated code
## blocks, which you can style using CSS. You can use [this example code][2] as
## a starting point.
##
##
## ### Github-Flavored Markdown
##
## Support for Github-Flavored Markdown extensions is planned, but not
## currently implemented.
##
## [1]: https://github.com/jwoudenberg/rvn
## [2]: https://github.com/jwoudenberg/jay/blob/main/example/static/style.css
from_markdown : Pages [Markdown] -> Pages [Html]
from_markdown = \pages ->
    unwrap pages
    |> List.map \page -> { page & processing: Markdown }
    |> wrap

## Wrap additional HTML around each of a set of HTML pages.
## This function is typically used to create page layouts.
##
## ```
## posts =
##     files ["posts/*.md"]
##     |> from_markdown
##     |> wrap_html layout
##
## layout = \{ content, path, meta } ->
##     Html.html {} [
##         Html.head {} [ Html.title {} [ Html.text meta.title ] ],
##         Html.body {} [
##             Html.h1 {} [ Html.text meta.title ],
##             content,
##         ]
##     ]
## ```
##
## `wrap_html` passes a record to the layout function with these fields:
##
## - `content`: The original HTML content of the page. Most of the time you
##   will want to include this somewhere in the returned HTML.
## - `path`: The path at which the current page will be served, for use in
##   `href` attributes.
## - `meta`: The frontmatter of markdown source files that included one,
##    and `{}` for all other pages.
wrap_html : Pages [Html], ({ content : Html, path : Str, meta : {}a } => Html) -> Pages [Html] where a implements Decoding
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

## Get information about all pages matching a pattern. This is intended to be
## used in combination with `wrap_html` or `replace_html`, for instance to
## create a navigation element with links to other pages.
##
## See the documentation of `wrap_html` for an example of how to use this.
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

## Replaces matching HTML tags with generated HTML content.
## This is typically used to create widgets.
##
## Suppose you want to create an index page of your blog, showing all your
## blog posts. Start by writting a markdown file:
##
## ```
## # My Blog
##
## A list of all my previous posts!
##
## <list-of-posts/>
## ```
##
## We can use `replace_html` to replace the custom `list-of-posts` HTML element
## with a list of posts. Here's how that would look:
##
## ```
## home_page =
##     files ["index.md"]
##     |> from_markdown
##     |> replace_html "list-of-posts" list_of_posts!
##
## list_of_posts! = \_ ->
##     posts = list! "posts/*"
##     links = List.map posts \post ->
##         Html.li {} [
##             Html.a
##                 { href: post.path }
##                 [Html.text post.meta.title],
##         ]
##     Html.ul {} links
## ```
##
## `replace_html` passes a record to the widget function with these fields:
##
## - `content`: The HTML content of the HTML tag that is replaced.
## - `attrs`: The HTML attributes of the HTML tag that is replaced.
## - `path`: The path at which the current page will be served, for use in
##   `href` attributes.
## - `meta`: The frontmatter of markdown source files that included one,
##    and `{}` for all other pages.
replace_html :
    Pages [Html],
    Str,
    ({ content : Html, attrs : {}attrs, path : Str, meta : {}a } => Html)
    -> Pages [Html]
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
