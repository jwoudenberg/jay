module [Pages, Content, PagesInternal, Metadata, wrap, unwrap]

Pages a := List Metadata -> PagesInternal

PagesInternal : {
    patterns : List Str,
    processing : [None, Ignore, Bootstrap, Markdown],
    pages : List Content,
}

Metadata : {
    path : Str,
    frontmatter : List U8,
}

Content : List
    [
        SourceFile,
        Snippet (List U8),
    ]

wrap : (List Metadata -> PagesInternal) -> Pages type
wrap = \internal -> @Pages internal

unwrap : Pages type -> (List Metadata -> PagesInternal)
unwrap = \@Pages internal -> internal
