module [Pages, Page, Xml, PageRule, HostPage, HostTag, SourceLoc, wrap, unwrap]

Pages a := List Page

Page : {
    patterns : List Str,
    processing : [None, Ignore, Bootstrap, Markdown, Xml],
    replace_tags : List Str,
    pipeline! : Xml, HostPage => Xml,
}

wrap = \internal -> @Pages internal

unwrap = \@Pages internal -> internal

PageRule : {
    patterns : List Str,
    processing : [None, Ignore, Bootstrap, Markdown, Xml],
    replace_tags : List Str,
}

HostPage : {
    # The index of the rule for this page in `main`
    rule_index : U32,
    # The destination path an output file will be placed at.
    path : Str,
    # Bytes containing a markdown's page frontmatter.
    meta : List U8,
    # The locations of tags in the source code,
    tags : List HostTag,
    # The length in bytes of the source file,
    len : U32,
}

HostTag : {
    index : U32,
    outer_start : U32,
    outer_end : U32,
    inner_start : U32,
    inner_end : U32,
    attributes : List U8,
}

Xml : List
        [
            FromSource SourceLoc,
            RocGenerated (List U8),
        ]

SourceLoc : {
    start : U32,
    end : U32,
}
