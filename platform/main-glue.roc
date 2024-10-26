platform "glue-types"
    requires {} { main : _ }
    exposes []
    packages {}
    imports []
    provides [mainForHost]

import Effect

GlueTypes : {
    a : Effect.Pages,
    b : Effect.Wrapper,
}

mainForHost : GlueTypes
mainForHost = main
