platform "jay"
    requires {} { main : Pages.Pages a }
    exposes [Pages, Html]
    packages {}
    imports []
    provides [mainForHost, runPipelineForHost!, getMetadataLengthForHost]

import Rvn
import Pages
import Pages.Internal

mainForHost : {} -> List Pages.Internal.PageRule
mainForHost = \{} ->
    List.map (Pages.Internal.unwrap main) \page -> {
        patterns: page.patterns,
        processing: page.processing,
        replaceTags: page.replaceTags,
    }

getMetadataLengthForHost : List U8 -> U64
getMetadataLengthForHost = \bytes ->
    { result, rest } = Decode.fromBytesPartial bytes Rvn.compact
    when result is
        Ok {} -> List.len bytes - List.len rest
        Err _ -> 0

runPipelineForHost! : Pages.Internal.HostPage => Pages.Internal.Xml
runPipelineForHost! = \hostPage ->
    page =
        when List.get (Pages.Internal.unwrap main) (Num.intCast hostPage.ruleIndex) is
            Ok x -> x
            Err OutOfBounds -> crash "unexpected out of bounds page rule"

    init = [FromSource { start: 0, end: hostPage.len }]

    page.pipeline! init hostPage
