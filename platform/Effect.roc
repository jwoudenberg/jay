hosted Effect
    exposes [copy, Pages, Xml]
    imports []

copy : Box Pages -> Task {} {}

Pages : {
    files : List Str,
    dirs : List Str,
}

Xml : List
    [
        SourceFile,
        Snippet (List U8),
    ]
