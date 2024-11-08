platform "glue-types"
    requires {} { main : _ }
    exposes []
    packages {}
    imports []
    provides [mainForHost]

import Pages.Internal

GlueTypes : {
    a : Pages.Internal.PageRule,
    b : Pages.Internal.HostPage,
    c : Pages.Internal.HostTag,
    d : Pages.Internal.Xml,
    e : Pages.Internal.SourceLoc,
}

mainForHost : GlueTypes
mainForHost = main
