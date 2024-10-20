platform "glue-types"
    requires {} { main : _ }
    exposes []
    packages {}
    imports []
    provides [mainForHost]

import Effect

GlueTypes : {
    a : Effect.Pages,
}

mainForHost : GlueTypes
mainForHost = main
