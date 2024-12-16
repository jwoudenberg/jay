platform "jay"
    requires {} { main : Pages.Pages a }
    exposes [Pages, Html]
    packages {}
    imports []
    provides [main_for_host, run_pipeline_for_host!, get_metadata_length_for_host]

import Rvn
import Pages
import Pages.Internal

main_for_host : {} -> List Pages.Internal.PageRule
main_for_host = \{} ->
    List.map (Pages.Internal.unwrap main) \page -> {
        patterns: page.patterns,
        processing: page.processing,
        replace_tags: page.replace_tags,
    }

get_metadata_length_for_host : List U8 -> U64
get_metadata_length_for_host = \bytes ->
    { result, rest } = Decode.fromBytesPartial bytes Rvn.compact
    when result is
        Ok {} -> List.len bytes - List.len rest
        Err _ -> 0

run_pipeline_for_host! : Pages.Internal.HostPage => Pages.Internal.Xml
run_pipeline_for_host! = \host_page ->
    page =
        when List.get (Pages.Internal.unwrap main) (Num.intCast host_page.ruleIndex) is
            Ok x -> x
            Err OutOfBounds -> crash "unexpected out of bounds page rule"

    init = [FromSource { start: 0, end: host_page.len }]

    page.pipeline! init host_page
