module [Pages, Html, node, text]

Pages : [
    FilesIn Str,
    Files (List Str),
    # SiteData
    #     {
    #         files : Dict Str Html,
    #         transformation : Html -> Html,
    #         metadata : Dict Str (List U8),
    #     },
]

Handle := {}

Stream := {}

Html := Stream
        [
            Raw Handle,
            Text Str,
            StartTag { name : Str, attributes : List (Str, Str) },
            EndTag Str,
        ]

node : Str, List (Str, Str), List Html -> Html

text : Str -> Html
