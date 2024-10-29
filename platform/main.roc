platform "jay"
    requires {} { main : List (Pages.Pages a) }
    exposes [Pages, Html]
    packages {}
    imports [PagesInternal, Pages]
    provides [mainForHost]

mainForHost : List (List PagesInternal.Metadata) -> List PagesInternal.PagesInternal
mainForHost = \metadata ->
    ruleCount = List.len main
    metaCount = List.len metadata
    if metaCount == 0 then
        List.map
            main
            \page -> (PagesInternal.unwrap page) PatternsOnly
    else if metaCount == ruleCount then
        List.map2
            main
            metadata
            \page, ruleMeta -> (PagesInternal.unwrap page) (Content ruleMeta)
    else
        crash "got $(Num.toStr ruleCount) page rules, but received metadata for $(Num.toStr metaCount)"
