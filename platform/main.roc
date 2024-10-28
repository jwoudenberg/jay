platform "jay"
    requires {} { main : List (Pages.Pages a) }
    exposes [Pages, Html]
    packages { rvn: "https://github.com/jwoudenberg/rvn/releases/download/0.2.0/omuMnR9ZyK4n5MaBqi7Gg73-KS50UMs-1nTu165yxvM.tar.br" }
    imports [PagesInternal, Pages]
    provides [mainForHost]

mainForHost : List (List PagesInternal.Metadata) -> List PagesInternal.PagesInternal
mainForHost = \metadata ->
    ruleCount = List.len main
    metaCount = List.len metadata
    if metaCount == 0 then
        List.map main \page ->
            (PagesInternal.unwrap page) []
    else if metaCount == ruleCount then
        List.map2 main metadata \page, ruleMeta ->
            (PagesInternal.unwrap page) ruleMeta
    else
        crash "got $(Num.toStr ruleCount) page rules, but received metadata for $(Num.toStr metaCount)"
