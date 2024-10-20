hosted Effect
    exposes [copy, Pages, Xml]
    imports []

copy : Box Pages -> Task {} {}

Pages : [
    FilesIn Str,
    Files (List Str),
]

Xml : List
    [
        SourceFile,
        Snippet (List U8),
    ]
