module [
    Html,
    attr,
    text,

    # elements
    a,
    h1,
    body,
    head,
    html,
    li,
    link,
    ul,
]

import XmlInternal

Html : XmlInternal.Xml

Attribute := (Str, Str)

attr : Str, Str -> Attribute

text : Str -> Html
text = XmlInternal.text

body = \attributes, children -> XmlInternal.node "body" attributes children

head = \attributes, children -> XmlInternal.node "head" attributes children

html = \attributes, children -> XmlInternal.node "html" attributes children

link = \attributes, children -> XmlInternal.node "link" attributes children

ul = \attributes, children -> XmlInternal.node "ul" attributes children

li = \attributes, children -> XmlInternal.node "li" attributes children

a = \attributes, children -> XmlInternal.node "a" attributes children

h1 = \attributes, children -> XmlInternal.node "a" attributes children
