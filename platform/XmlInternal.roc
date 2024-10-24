module [Xml, node, text]

import Effect

Xml := Effect.Xml

node : Str, {}attributes, List Xml -> Xml where attributes implements Encoding

text : Str -> Xml
