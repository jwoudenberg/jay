hosted Effect
    exposes [copy, Pages, Xml]
    imports []

copy : Box Pages -> Task {} {}

Pages : {
    patterns : List Str,
    processing : [None, Ignore, Markdown],
    transforms : List (Xml -> Xml),
}

Xml : List
    [
        SourceFile,
        Snippet (List U8),
    ]
