module [Xml, node, text]

import Effect

Xml := Effect.Xml

node : Str, List (Str, Str), List Xml -> Xml

text : Str -> Xml
