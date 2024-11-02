module [Pages, Slice, PagesInternal, Metadata, wrap, unwrap]

Pages a := List Metadata -> PagesInternal

PagesInternal : {
    patterns : List Str,
    processing : [None, Ignore, Bootstrap, Markdown],
    replaceTags : List Str,
    pages : List Slice,
}

Metadata : {
    # The destination path an output file will be placed at.
    path : Str,
    # Bytes containing a markdown's page frontmatter.
    frontmatter : List U8,
    # The source content of a page.
    source : List Slice,
    # Data to run replaceHtml functions with. Containst just attributes
    # The outer list represents one replaceHtml call, the middle list contains
    # potentially multiple elements matched with that replacement, the inner
    # list of u8's represents the attribute for the matched element.
    replacements : List (List (List U8)),
}

Slice : List
    [
        FromSource U64,
        Slice (List U8),
    ]

wrap : (List Metadata -> PagesInternal) -> Pages type
wrap = \internal -> @Pages internal

unwrap : Pages type -> (List Metadata -> PagesInternal)
unwrap = \@Pages internal -> internal
