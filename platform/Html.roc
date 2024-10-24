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

import XmlInternal

Html : XmlInternal.Xml

Attribute := (Str, Str)

attr : Str, Str -> Attribute

text : Str -> Html
text = XmlInternal.text

GlobalAttributes : {
    id ? Str,
    class ? Str,
    onclick ? Str,
}

body : { lang ? Str }GlobalAttributes, List Html -> Html
body = \attributes, children -> XmlInternal.node "body" attributes children

head : GlobalAttributes, List Html -> Html
head = \attributes, children -> XmlInternal.node "head" attributes children

html : GlobalAttributes, List Html -> Html
html = \attributes, children -> XmlInternal.node "html" attributes children

link : { href ? Str, rel ? Str, type ? Str }GlobalAttributes, List Html -> Html
link = \attributes, children -> XmlInternal.node "link" attributes children

ul : GlobalAttributes, List Html -> Html
ul = \attributes, children -> XmlInternal.node "ul" attributes children

li : GlobalAttributes, List Html -> Html
li = \attributes, children -> XmlInternal.node "li" attributes children

a : { href ? Str }GlobalAttributes, List Html -> Html
a = \attributes, children -> XmlInternal.node "a" attributes children
