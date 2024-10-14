module [
    Html,
    attr,
    text,

    # elements
    a,
    body,
    head,
    html,
    li,
    link,
    ul,
]

import Internal

Html : Internal.Html

Attribute := (Str, Str)

mkNode : Str -> (List Attribute, List Html -> Html)
mkNode = \tag -> \attributes, children ->
        Internal.node
            tag
            (List.map attributes (\@Attribute pair -> pair))
            children

attr : Str, Str -> Attribute

text : Str -> Html
text = Internal.text

a = mkNode "a"
body = mkNode "body"
head = mkNode "head"
html = mkNode "html"
li = mkNode "li"
link = mkNode "link"
ul = mkNode "ul"
