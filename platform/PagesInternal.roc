module [Pages, Content, PagesInternal, Request, Metadata, wrap, unwrap]

Pages a := Request -> PagesInternal

PagesInternal : {
    patterns : List Str,
    processing : [None, Ignore, Bootstrap, Markdown],
    content : Content,
}

Request : [PatternsOnly, Content (List Metadata)]

Metadata : {
    path : Str,
    frontmatter : List U8,
}

Content : List
    [
        SourceFile,
        Snippet (List U8),
    ]

wrap : (Request -> PagesInternal) -> Pages type
wrap = \internal -> @Pages internal

unwrap : Pages type -> (Request -> PagesInternal)
unwrap = \@Pages internal -> internal
