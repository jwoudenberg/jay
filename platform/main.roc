platform "jay"
    requires {} { main : List (Pages.Pages a) }
    exposes [Pages, Html]
    packages {}
    imports []
    provides [mainForHost, getMetadataLengthForHost]

import Rvn
import Pages
import PagesInternal

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

getMetadataLengthForHost : List U8 -> U64
getMetadataLengthForHost = \bytes ->
    { result, rest } = Decode.fromBytesPartial bytes Rvn.compact
    when result is
        Ok {} -> List.len bytes - List.len rest
        Err _ -> 0
