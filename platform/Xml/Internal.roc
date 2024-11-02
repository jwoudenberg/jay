module [Xml, node, text, wrap, unwrap]

import PagesInternal exposing [Slice]
import Xml.Attributes

Xml := Slice

wrap : Slice -> Xml
wrap = \xml -> @Xml xml

unwrap : Xml -> Slice
unwrap = \@Xml xml -> xml

# Escaping performed by this function:
# https://www.w3.org/TR/REC-xml/#NT-Name
#
# - Tag name
# Currently not escaped. 'node' is currently used by internal
# functions that provided harcoded name strings only. If in the
# future name might be provided by application authors then we might
# want to escape it.
#
# - Attribute names
# Attribute names are taken from field names. We're relying on Roc's
# limitations on field names being stricter than XML's limitations on names.
#
# - Attribute values
# Escaping '<', '&', and '"'. We don't escape the single quote character
# because we consistently encode attributes in double quotes.
#
# - Text content
# Escaping '<' and '&', according to the XML spec.
node : Str, {}attributes, List Xml -> Xml where attributes implements Encoding
node = \tagName, attributes, children ->
    openTag =
        Str.toUtf8 "<$(tagName)"
        |> Encode.append attributes Xml.Attributes.formatter
        |> List.concatUtf8 ">"

    closeTag =
        Str.toUtf8 "</$(tagName)>"

    [Slice openTag]
    |> (\html -> List.walk children html (\acc, @Xml child -> List.concat acc child))
    |> List.append (Slice closeTag)
    |> wrap

expect
    # Encode node without attributes.
    xml = xmlToStrForTests (node "span" {} [])
    xml == "<span></span>"

expect
    # Don't include empty attributes.
    xml = xmlToStrForTests (node "span" { empty: "" } [])
    xml == "<span></span>"

expect
    # Encode node with multiple attributes.
    attrs = { class: "green", id: "key-point" }
    children = [text "cats", text "kill"]
    xml = xmlToStrForTests (node "span" attrs children)
    xml == "<span class=\"green\" id=\"key-point\">catskill</span>"

expect
    # Encode nested records as hyphen-separated attributes.
    xml = xmlToStrForTests (node "button" { aria: { disabled: "true" } } [])
    xml == "<button aria-disabled=\"true\"></button>"

text : Str -> Xml
text = \str ->
    bytes = Xml.Attributes.escape (Str.toUtf8 str) [
        { needle: ['<'], replacement: ['&', 'l', 't', ';'] },
        { needle: ['&'], replacement: ['&', 'a', 'm', 'p', ';'] },
    ]

    @Xml [Slice bytes]

xmlToStrForTests : Xml -> Str
xmlToStrForTests = \xml ->
    unwrap xml
    |> List.map \snippet ->
        when snippet is
            Slice bytes ->
                when Str.fromUtf8 bytes is
                    Ok str -> str
                    Err err -> crash "Failed to convert bytes to Str: $(Inspect.toStr err)"

            FromSource num ->
                "{SOURCE-$(Num.toStr num)}"
    |> Str.joinWith ""

