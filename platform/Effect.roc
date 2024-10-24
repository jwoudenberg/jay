hosted Effect
    exposes [copy, Pages, Xml]
    imports []

copy : Box Pages -> Task {} {}

Pages : {
    patterns : List Str,
    processing : [None, Ignore, Markdown],
}

Xml : List
    [
        SourceFile,
        Snippet (List U8),
    ]
