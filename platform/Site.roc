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

import Internal
import Effect

Html : Internal.Html

Markdown := {}

Pages a := [
    FilesIn Path,
    # Files (List Path),
    # SiteData
    #     {
    #         files : Dict Path Html,
    #         transformation : Html -> Html,
    #         metadata : Dict Path (List U8),
    #     },
]

Path : Str

copy : Pages content -> Task {} []
copy = \@Pages (FilesIn path) -> Effect.copy path

# Parse directory structure and rewrite main.roc with initial implementation.
bootstrap : Task {} []

files : List Path -> Pages content

filesIn : Path -> Pages content
filesIn = \path -> @Pages (FilesIn path)

meta : Pages _ -> List { path : Path }a

fromMarkdown : Pages Markdown -> Pages Html

wrapHtml : Pages Html, (Html, meta -> Html) -> Pages Html

# Replace an HTML element in the passed in pages.
replaceHtml :
    Pages Html,
    Str,
    ({ meta : meta, attrs : attrs, content : Html } -> Html)
    -> Pages Html

# Advanced: Used to create pages from nothing, i.e. not from a template
page : Path, Html, meta -> Pages Html

# Advanced: Used to implement functions like 'fromMarkdown'
toHtml :
    {
        extension : Str,
        parser : List U8 -> (Html, meta),
    },
    Pages content
    -> Pages Html
