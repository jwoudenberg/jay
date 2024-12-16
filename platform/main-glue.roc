platform "glue-types"
    requires {} { main : _ }
    exposes []
    packages {}
    imports []
    provides [main_for_host]

import Pages.Internal

GlueTypes : {
    a : Pages.Internal.PageRule,
    b : Pages.Internal.HostPage,
    c : Pages.Internal.HostTag,
    d : Pages.Internal.Xml,
    e : Pages.Internal.SourceLoc,
}

main_for_host : GlueTypes
main_for_host = main
