platform "glue-types"
    requires {} { main : _ }
    exposes []
    packages {}
    imports []
    provides [mainForHost]

import PagesInternal

GlueTypes : {
    a : PagesInternal.PageRule,
    b : PagesInternal.HostPage,
    c : PagesInternal.HostTag,
    d : PagesInternal.Xml,
    e : PagesInternal.SourceLoc,
}

mainForHost : GlueTypes
mainForHost = main
