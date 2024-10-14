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

Html : Internal.Html

Markdown := {}

Pages a := [
    Files (List Path),
    FilesIn Path,
    SiteData
        {
            files : Dict Path Html,
            transformation : Html -> Html,
            metadata : Dict Path (List U8),
        },
]

Path : Str

copy : Pages content -> Task {} []

# Parse directory structure and rewrite main.roc with initial implementation.
bootstrap : Task {} []

files : List Path -> Pages content

filesIn : Path -> Pages content

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
