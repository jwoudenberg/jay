hosted Effect
    exposes [copy, Pages, Wrapper]
    imports []

copy : Box Pages -> Task {} {}

Pages : {
    patterns : List Str,
    processing : [None, Ignore, Markdown],
    wrapper : Wrapper,
}

Wrapper : List
    [
        SourceFile,
        Snippet (List U8),
    ]
