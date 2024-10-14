module [Html, node, text]

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
