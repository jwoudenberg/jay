module [Attributes, formatter, escape]

formatter : Attributes
formatter = @Attributes { words: [] }

# Formatter used for encoding HTML attributes. It currently expects records
# with string fields as an input.
#
# Records can be nested. This:
#
#     { aria: { disabled: "true" } }
#
# Gets encoded as:
#
#     aria-disabled="true"
#
# The words property in the formatter keeps track growing attribute name as
# the decoder moves deeper into a nested record.
#
Attributes := { words : List Str }
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
        DecoderFormatting {
            u8: decodeU8,
            u16: decodeU16,
            u32: decodeU32,
            u64: decodeU64,
            u128: decodeU128,
            i8: decodeI8,
            i16: decodeI16,
            i32: decodeI32,
            i64: decodeI64,
            i128: decodeI128,
            f32: decodeF32,
            f64: decodeF64,
            dec: decodeDec,
            bool: decodeBool,
            string: decodeString,
            list: decodeList,
            record: decodeRecord,
            tuple: decodeTuple,
        },
    ]

escapeRules = [
    { needle: ['<'], replacement: ['&', 'l', 't', ';'] },
    { needle: ['&'], replacement: ['&', 'a', 'm', 'p', ';'] },
    { needle: ['"'], replacement: ['&', 'q', 'u', 'o', 't', ';'] },
]

unescapeRules = List.map escapeRules \{ needle, replacement } ->
    { needle: replacement, replacement: needle }

escape : List U8, List { needle : List U8, replacement : List U8 } -> List U8
escape = \unescaped, replacements ->
    findMatch = \bytes ->
        List.findFirst replacements \{ needle } ->
            List.startsWith bytes needle

    escapeOrKeep = \state, index ->
        when findMatch (List.dropFirst unescaped index) is
            Ok { needle, replacement } ->
                afterCopy = copySlice state
                { afterCopy &
                    start: afterCopy.start + List.len needle,
                    escaped: List.concat afterCopy.escaped replacement,
                }

            Err NotFound -> { state & len: state.len + 1 }

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

    List.walk
        (List.range { start: At 0, end: Before (List.len unescaped) })
        init
        escapeOrKeep
    |> copySlice
    |> .escaped

expect
    actual = escape
        (Str.toUtf8 "abXcdXXef")
        [{ needle: ['X'], replacement: ['*', '*'] }]
    Str.fromUtf8 actual == Ok "ab**cd****ef"

expect
    actual = escape
        (Str.toUtf8 "abXcdXYef")
        [{ needle: ['X', 'Y'], replacement: ['*', '*'] }]
    Str.fromUtf8 actual == Ok "abXcd**ef"

encodeU8 : U8 -> Encoder Attributes
encodeU8 = \_ -> crash "can't encode U8"

encodeU16 : U16 -> Encoder Attributes
encodeU16 = \_ -> crash "can't encode U16"

encodeU32 : U32 -> Encoder Attributes
encodeU32 = \_ -> crash "can't encode U32"

encodeU64 : U64 -> Encoder Attributes
encodeU64 = \_ -> crash "can't encode U64"

encodeU128 : U128 -> Encoder Attributes
encodeU128 = \_ -> crash "can't encode U128"

encodeI8 : I8 -> Encoder Attributes
encodeI8 = \_ -> crash "can't encode I8"

encodeI16 : I16 -> Encoder Attributes
encodeI16 = \_ -> crash "can't encode I16"

encodeI32 : I32 -> Encoder Attributes
encodeI32 = \_ -> crash "can't encode I32"

encodeI64 : I64 -> Encoder Attributes
encodeI64 = \_ -> crash "can't encode I64"

encodeI128 : I128 -> Encoder Attributes
encodeI128 = \_ -> crash "can't encode I128"

encodeF32 : F32 -> Encoder Attributes
encodeF32 = \_ -> crash "can't encode F32"

encodeF64 : F64 -> Encoder Attributes
encodeF64 = \_ -> crash "can't encode F64"

encodeDec : Dec -> Encoder Attributes
encodeDec = \_ -> crash "can't encode Dec"

encodeBool : Bool -> Encoder Attributes
encodeBool = \_ -> crash "can't encode Bool"

encodeString : Str -> Encoder Attributes
encodeString = \str ->
    Encode.custom \bytes, @Attributes { words } ->
        if Str.isEmpty str then
            bytes
        else
            escaped = escape (Str.toUtf8 str) [
                { needle: ['<'], replacement: ['&', 'l', 't', ';'] },
                { needle: ['&'], replacement: ['&', 'a', 'm', 'p', ';'] },
                { needle: ['"'], replacement: ['&', 'q', 'u', 'o', 't', ';'] },
            ]

            key = Str.joinWith words "-"

            bytes
            |> List.concat [' ']
            |> List.concat (Str.toUtf8 key)
            |> List.concat ['=', '"']
            |> List.concat escaped
            |> List.concat ['"']

encodeList : List elem, (elem -> Encoder Attributes) -> Encoder Attributes
encodeList = \_, _ -> crash "can't encode List"

encodeRecord : List { key : Str, value : Encoder Attributes } -> Encoder Attributes
encodeRecord = \fields ->
    Encode.custom \bytes, @Attributes fmt ->
        List.walk fields bytes \acc, { key, value } ->
            newFmt = @Attributes { fmt & words: List.append fmt.words key }
            Encode.appendWith acc value newFmt

encodeTuple : List (Encoder Attributes) -> Encoder Attributes
encodeTuple = \_ -> crash "can't encode Tuple"

encodeTag : Str, List (Encoder Attributes) -> Encoder Attributes
encodeTag = \_, _ -> crash "can't encode Tag"

decodeU8 : Decoder U8 Attributes
decodeU8 = Decode.custom \_bytes, @Attributes _ -> crash "can't decode U8"

decodeU16 : Decoder U16 Attributes
decodeU16 = Decode.custom \_bytes, @Attributes _ -> crash "can't decode U16"

decodeU32 : Decoder U32 Attributes
decodeU32 = Decode.custom \_bytes, @Attributes _ -> crash "can't decode U32"

decodeU64 : Decoder U64 Attributes
decodeU64 = Decode.custom \_bytes, @Attributes _ -> crash "can't decode U64"

decodeU128 : Decoder U128 Attributes
decodeU128 = Decode.custom \_bytes, @Attributes _ -> crash "can't decode U128"

decodeI8 : Decoder I8 Attributes
decodeI8 = Decode.custom \_bytes, @Attributes _ -> crash "can't decode I8"

decodeI16 : Decoder I16 Attributes
decodeI16 = Decode.custom \_bytes, @Attributes _ -> crash "can't decode I16"

decodeI32 : Decoder I32 Attributes
decodeI32 = Decode.custom \_bytes, @Attributes _ -> crash "can't decode I32"

decodeI64 : Decoder I64 Attributes
decodeI64 = Decode.custom \_bytes, @Attributes _ -> crash "can't decode I64"

decodeI128 : Decoder I128 Attributes
decodeI128 = Decode.custom \_bytes, @Attributes _ -> crash "can't decode I128"

decodeF32 : Decoder F32 Attributes
decodeF32 = Decode.custom \_bytes, @Attributes _ -> crash "can't decode F32"

decodeF64 : Decoder F64 Attributes
decodeF64 = Decode.custom \_bytes, @Attributes _ -> crash "can't decode F64"

decodeDec : Decoder Dec Attributes
decodeDec = Decode.custom \_bytes, @Attributes _ -> crash "can't decode Dec"

decodeBool : Decoder Bool Attributes
decodeBool = Decode.custom \_bytes, @Attributes _ -> crash "can't decode Bool"

decodeString : Decoder Str Attributes
decodeString = Decode.custom \bytes, @Attributes _ ->
    matchRemainderOfString = \quoteChar, rest ->
        when List.splitFirst rest quoteChar is
            Err NotFound -> { rest, result: Err TooShort }
            Ok { before, after } ->
                when Str.fromUtf8 (escape before unescapeRules) is
                    Err _ -> { rest, result: Err TooShort }
                    Ok str -> { rest: after, result: Ok str }

    when bytes is
        ['"', .. as rest] -> matchRemainderOfString '"' rest
        ['\'', .. as rest] -> matchRemainderOfString '\'' rest
        _ -> { rest: bytes, result: Err TooShort }

decodeList : Decoder elem Attributes -> Decoder (List elem) Attributes
decodeList = \_elemDecoder ->
    Decode.custom \_bytes, @Attributes _ -> crash "can't decode List"

RecordState state : { rest : List U8, state : state }

decodeRecord :
    state,
    (state, Str -> [Keep (Decoder state Attributes), Skip]),
    (state, Attributes -> Result val DecodeError)
    -> Decoder val Attributes
decodeRecord =
    \initialState, stepField, finalizer ->
        Decode.custom \bytes, fmt ->

            parseValue : Str, RecordState state -> DecodeResult state
            parseValue = \key, { rest, state } ->
                when stepField state key is
                    Skip ->
                        result = Decode.decodeWith rest decodeString fmt
                        when result.result is
                            Ok _ -> { result: Ok state, rest: result.rest }
                            Err err -> { result: Err err, rest: result.rest }

                    Keep decoder ->
                        result = Decode.decodeWith rest decoder fmt
                        when result.result is
                            Ok newState ->
                                { result: Ok newState, rest: result.rest }

                            Err _ -> result

            parseAttribute : RecordState state -> DecodeResult state
            parseAttribute = \{ rest, state } ->
                when List.splitFirst rest '=' is
                    Err NotFound -> { rest, result: Err TooShort }
                    Ok { before, after } ->
                        when Str.fromUtf8 before is
                            Err _ -> { rest: after, result: Err TooShort }
                            Ok key -> parseValue key { rest: after, state }

            loop : RecordState state -> DecodeResult state
            loop = \{ rest, state } ->
                when skipWhitespace rest is
                    ['>', ..] -> { rest, result: Ok state }
                    after ->
                        result = parseAttribute { rest: after, state }
                        when result.result is
                            Ok newState ->
                                loop { rest: result.rest, state: newState }

                            Err _ -> result

            when loop { rest: bytes, state: initialState } is
                { rest, result: Err err } ->
                    { rest, result: Err err }

                { rest, result: Ok state } ->
                    {
                        result: finalizer state fmt,
                        rest,
                    }

decodeTuple :
    state,
    (state, U64 -> [Next (Decoder state Attributes), TooLong]),
    (state -> Result val DecodeError)
    -> Decoder val Attributes
decodeTuple =
    \_initialState, _stepField, _finalizer ->
        Decode.custom \_bytes, @Attributes _ -> crash "can't decode Tuple"

expect
    { result } =
        Decode.fromBytesPartial
            (Str.toUtf8 " elm='leafy' \n pine=\"needly\"  >")
            formatter
    result == Ok { elm: "leafy", pine: "needly" }

whitespace : Set U8
whitespace = Set.fromList [' ', '\t', '\n']

skipWhitespace : List U8 -> List U8
skipWhitespace = \bytes ->
    List.dropIf bytes \byte -> Set.contains whitespace byte

expect
    result = skipWhitespace []
    result == []

expect
    result = skipWhitespace [' ', '\t', '\n']
    result == []

expect
    result = skipWhitespace [' ', '\t', '\n', 'a', 'b', 'c']
    result == ['a', 'b', 'c']
