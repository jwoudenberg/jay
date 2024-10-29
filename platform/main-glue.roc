platform "glue-types"
    requires {} { main : _ }
    exposes []
    packages {}
    imports []
    provides [mainForHost]

import PagesInternal

GlueTypes : {
    a : PagesInternal.PagesInternal,
    b : PagesInternal.Content,
    c : PagesInternal.Metadata,
}

mainForHost : GlueTypes
mainForHost = main
