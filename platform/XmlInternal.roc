module [Xml, node, text, wrap, unwrap]

import Effect

Xml := Effect.Wrapper

wrap : Effect.Wrapper -> Xml
wrap = \xml -> @Xml xml

unwrap : Xml -> Effect.Wrapper
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
        |> Encode.append attributes (@HtmlAttributes {})
        |> List.concatUtf8 ">"

    closeTag =
        Str.toUtf8 "</$(tagName)>"

    [Snippet openTag]
    |> (\html -> List.walk children html (\acc, @Xml child -> List.concat acc child))
    |> List.append (Snippet closeTag)
    |> wrap

expect
    attrs = { class: "green", id: "key-point" }
    children = [
        @Xml [Snippet (Str.toUtf8 "cats")],
        @Xml [Snippet (Str.toUtf8 "kill")],
    ]

    unwrap (node "span" attrs children)
    == [
        Snippet (Str.toUtf8 "<span class=\"green\" id=\"key-point\">"),
        Snippet (Str.toUtf8 "cats"),
        Snippet (Str.toUtf8 "kill"),
        Snippet (Str.toUtf8 "</span>"),
    ]

text : Str -> Xml
text = \str ->
    bytes = escape (Str.toUtf8 str) \byte ->
        when byte is
            '<' -> Replace ['&', 'l', 't', ';']
            '&' -> Replace ['&', 'a', 'm', 'p', ';']
            _ -> Keep

    @Xml [Snippet bytes]

escape : List U8, (U8 -> [Replace (List U8), Keep]) -> List U8
escape = \unescaped, escapeByte ->
    escapeOrKeep = \state, byte ->
        when escapeByte byte is
            Replace replacement ->
                afterCopy = copySlice state
                { afterCopy &
                    start: afterCopy.start + 1,
                    escaped: List.concat afterCopy.escaped replacement,
                }

            Keep -> { state & len: state.len + 1 }

    copySlice = \{ start, len, escaped } -> {
        start: start + len,
        len: 0,
        escaped: List.concat escaped (List.sublist unescaped { start, len }),
    }

    init = {
        escaped: List.withCapacity (List.len unescaped),
        start: 0,
        len: 0,
    }

    List.walk unescaped init escapeOrKeep
    |> copySlice
    |> .escaped

expect
    actual = escape (Str.toUtf8 "abXcdXXef") \byte ->
        when byte is
            'X' -> Replace ['*', '*']
            _ -> Keep

    Str.fromUtf8 actual == Ok "ab**cd****ef"

HtmlAttributes := {}
    implements [
        EncoderFormatting {
            u8: encodeU8,
            u16: encodeU16,
            u32: encodeU32,
            u64: encodeU64,
            u128: encodeU128,
            i8: encodeI8,
            i16: encodeI16,
            i32: encodeI32,
            i64: encodeI64,
            i128: encodeI128,
            f32: encodeF32,
            f64: encodeF64,
            dec: encodeDec,
            bool: encodeBool,
            string: encodeString,
            list: encodeList,
            record: encodeRecord,
            tuple: encodeTuple,
            tag: encodeTag,
        },
    ]

encodeU8 : U8 -> Encoder HtmlAttributes
encodeU8 = \_ -> crash "can't encode U8"

encodeU16 : U16 -> Encoder HtmlAttributes
encodeU16 = \_ -> crash "can't encode U16"

encodeU32 : U32 -> Encoder HtmlAttributes
encodeU32 = \_ -> crash "can't encode U32"

encodeU64 : U64 -> Encoder HtmlAttributes
encodeU64 = \_ -> crash "can't encode U64"

encodeU128 : U128 -> Encoder HtmlAttributes
encodeU128 = \_ -> crash "can't encode U128"

encodeI8 : I8 -> Encoder HtmlAttributes
encodeI8 = \_ -> crash "can't encode I8"

encodeI16 : I16 -> Encoder HtmlAttributes
encodeI16 = \_ -> crash "can't encode I16"

encodeI32 : I32 -> Encoder HtmlAttributes
encodeI32 = \_ -> crash "can't encode I32"

encodeI64 : I64 -> Encoder HtmlAttributes
encodeI64 = \_ -> crash "can't encode I64"

encodeI128 : I128 -> Encoder HtmlAttributes
encodeI128 = \_ -> crash "can't encode I128"

encodeF32 : F32 -> Encoder HtmlAttributes
encodeF32 = \_ -> crash "can't encode F32"

encodeF64 : F64 -> Encoder HtmlAttributes
encodeF64 = \_ -> crash "can't encode F64"

encodeDec : Dec -> Encoder HtmlAttributes
encodeDec = \_ -> crash "can't encode Dec"

encodeBool : Bool -> Encoder HtmlAttributes
encodeBool = \_ -> crash "can't encode Bool"

encodeString : Str -> Encoder HtmlAttributes
encodeString = \str ->
    Encode.custom \bytes, @HtmlAttributes _ ->
        escaped = escape (Str.toUtf8 str) \byte ->
            when byte is
                '<' -> Replace ['&', 'l', 't', ';']
                '&' -> Replace ['&', 'a', 'm', 'p', ';']
                '"' -> Replace ['&', 'q', 'u', 'o', 't', ';']
                _ -> Keep
        List.concat bytes escaped

encodeList : List elem, (elem -> Encoder HtmlAttributes) -> Encoder HtmlAttributes
encodeList = \_, _ -> crash "can't encode List"

encodeRecord : List { key : Str, value : Encoder HtmlAttributes } -> Encoder HtmlAttributes
encodeRecord = \fields ->
    Encode.custom \bytes, fmt ->
        addAttribute = \acc, { key, value } ->
            acc
            |> List.concat [' ']
            |> List.concat (Str.toUtf8 key)
            |> List.concat ['=', '"']
            |> Encode.appendWith value fmt
            |> List.concat ['"']

        List.walk fields bytes addAttribute

encodeTuple : List (Encoder HtmlAttributes) -> Encoder HtmlAttributes
encodeTuple = \_ -> crash "can't encode Tuple"

encodeTag : Str, List (Encoder HtmlAttributes) -> Encoder HtmlAttributes
encodeTag = \_, _ -> crash "can't encode Tag"
