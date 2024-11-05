platform "jay"
    requires {} { main : List (Pages.Pages a) }
    exposes [Pages, Html]
    packages {}
    imports []
    provides [mainForHost, runPipelineForHost, getMetadataLengthForHost]

import Rvn
import Pages
import PagesInternal

mainForHost : {} -> List PagesInternal.PageRule
mainForHost = \{} ->
    List.map main \page ->
        internal = PagesInternal.unwrap page
        {
            patterns: internal.patterns,
            processing: internal.processing,
            replaceTags: internal.replaceTags,
        }

getMetadataLengthForHost : List U8 -> U64
getMetadataLengthForHost = \bytes ->
    { result, rest } = Decode.fromBytesPartial bytes Rvn.compact
    when result is
        Ok {} -> List.len bytes - List.len rest
        Err _ -> 0

runPipelineForHost : PagesInternal.HostPage -> PagesInternal.Xml
runPipelineForHost = \hostPage ->
    page =
        when List.get main (Num.intCast hostPage.ruleIndex) is
            Ok x -> PagesInternal.unwrap x
            Err OutOfBounds -> crash "unexpected out of bounds page rule"

    init = [FromSource { start: 0, end: hostPage.len }]

    page.pipeline init hostPage
