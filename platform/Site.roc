module [
    Pages,
    Html,
    bootstrap,
    copy,
    files,
    filesIn,
    meta,
    fromMarkdown,
    wrapHtml,
    replaceHtml,
    page,
    toHtml,
]

import Effect
import Effect
import Html

Html : Html.Html

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
files = \paths -> @Pages (Files paths)

filesIn : Str -> Pages content
filesIn = \path -> @Pages (FilesIn path)

meta : Pages _ -> List { path : Str }a

fromMarkdown : Pages Markdown -> Pages Html

wrapHtml : Pages Html, (Html, meta -> Html) -> Pages Html

# Replace an HTML element in the passed in pages.
replaceHtml :
    Pages Html,
    Str,
    ({ meta : meta, attrs : attrs, content : Html } -> Html)
    -> Pages Html

# Advanced: Used to create pages from nothing, i.e. not from a template
page : Str, Html, meta -> Pages Html

# Advanced: Used to implement functions like 'fromMarkdown'
toHtml :
    {
        extension : Str,
        parser : List U8 -> (Html, meta),
    },
    Pages content
    -> Pages Html
