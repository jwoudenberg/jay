module [
    Pages,
    bootstrap,
    copy,
    files,
    filesIn,
    meta,
    fromMarkdown,
    wrapHtml,
    replaceHtml,
]

Pages := {}

Path : Str

copy : Pages content -> Task {} []

# Parse directory structure and rewrite main.roc with initial implementation.
bootstrap : Task {} []

files : List Path -> Pages content

filesIn : Path -> Pages content

meta : Pages _ -> List { path : Path }a

fromMarkdown : Pages Markdown _ -> Pages Html

wrapHtml : Pages Html, (Html -> Html) -> Pages Html

replaceHtml : Pages Html, Str, (meta, args -> Html) -> Pages Html

# Advanced: Used to create pages from nothing, i.e. not from a template
page : Path, content, meta -> Pages content

# Advanced: Used to implement functions like 'fromMarkdown'
toHtml : { extension : Str, render : a -> (Html, meta) }, Pages content -> Pages Html
