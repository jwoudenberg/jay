module [Pages, Content, PagesInternal, wrap, unwrap]

Pages a := PagesInternal

PagesInternal : {
    patterns : List Str,
    processing : [None, Ignore, Markdown],
    content : Content,
}

Content : List
    [
        SourceFile,
        Snippet (List U8),
    ]

wrap : PagesInternal -> Pages type
wrap = \xml -> @Pages xml

unwrap : Pages type -> PagesInternal
unwrap = \@Pages xml -> xml
