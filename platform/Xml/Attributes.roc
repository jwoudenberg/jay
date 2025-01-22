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
            u8: encode_u8,
            u16: encode_u16,
            u32: encode_u32,
            u64: encode_u64,
            u128: encode_u128,
            i8: encode_i8,
            i16: encode_i16,
            i32: encode_i32,
            i64: encode_i64,
            i128: encode_i128,
            f32: encode_f32,
            f64: encode_f64,
            dec: encode_dec,
            bool: encode_bool,
            string: encode_string,
            list: encode_list,
            record: encode_record,
            tuple: encode_tuple,
            tag: encode_tag,
        },
        DecoderFormatting {
            u8: decode_u8,
            u16: decode_u16,
            u32: decode_u32,
            u64: decode_u64,
            u128: decode_u128,
            i8: decode_i8,
            i16: decode_i16,
            i32: decode_i32,
            i64: decode_i64,
            i128: decode_i128,
            f32: decode_f32,
            f64: decode_f64,
            dec: decode_dec,
            bool: decode_bool,
            string: decode_string,
            list: decode_list,
            record: decode_record,
            tuple: decode_tuple,
        },
    ]

escape_rules = [
    { needle: ['<'], replacement: ['&', 'l', 't', ';'] },
    { needle: ['&'], replacement: ['&', 'a', 'm', 'p', ';'] },
    { needle: ['"'], replacement: ['&', 'q', 'u', 'o', 't', ';'] },
]

unescape_rules = List.map escape_rules |{ needle, replacement }|
    { needle: replacement, replacement: needle }

escape : List U8, List { needle : List U8, replacement : List U8 } -> List U8
escape = |unescaped, replacements|
    find_match = |bytes|
        List.find_first replacements |{ needle }|
            List.starts_with bytes needle

    escape_or_keep = |state, index|
        when find_match (List.drop_first unescaped index) is
            Ok { needle, replacement } ->
                after_copy = copy_slice state
                { after_copy &
                    start: after_copy.start + List.len needle,
                    escaped: List.concat after_copy.escaped replacement,
                }

            Err NotFound -> { state & len: state.len + 1 }

    copy_slice = |{ start, len, escaped }| {
        start: start + len,
        len: 0,
        escaped: List.concat escaped (List.sublist unescaped { start, len }),
    }

    init = {
        escaped: List.with_capacity (List.len unescaped),
        start: 0,
        len: 0,
    }

    List.walk
        (List.range { start: At 0, end: Before (List.len unescaped) })
        init
        escape_or_keep
    |> copy_slice
    |> .escaped

expect
    actual = escape
        (Str.to_utf8 "abXcdXXef")
        [{ needle: ['X'], replacement: ['*', '*'] }]
    Str.from_utf8 actual == Ok "ab**cd****ef"

expect
    actual = escape
        (Str.to_utf8 "abXcdXYef")
        [{ needle: ['X', 'Y'], replacement: ['*', '*'] }]
    Str.from_utf8 actual == Ok "abXcd**ef"

encode_u8 : U8 -> Encoder Attributes
encode_u8 = |_| crash "can't encode U8"

encode_u16 : U16 -> Encoder Attributes
encode_u16 = |_| crash "can't encode U16"

encode_u32 : U32 -> Encoder Attributes
encode_u32 = |_| crash "can't encode U32"

encode_u64 : U64 -> Encoder Attributes
encode_u64 = |_| crash "can't encode U64"

encode_u128 : U128 -> Encoder Attributes
encode_u128 = |_| crash "can't encode U128"

encode_i8 : I8 -> Encoder Attributes
encode_i8 = |_| crash "can't encode I8"

encode_i16 : I16 -> Encoder Attributes
encode_i16 = |_| crash "can't encode I16"

encode_i32 : I32 -> Encoder Attributes
encode_i32 = |_| crash "can't encode I32"

encode_i64 : I64 -> Encoder Attributes
encode_i64 = |_| crash "can't encode I64"

encode_i128 : I128 -> Encoder Attributes
encode_i128 = |_| crash "can't encode I128"

encode_f32 : F32 -> Encoder Attributes
encode_f32 = |_| crash "can't encode F32"

encode_f64 : F64 -> Encoder Attributes
encode_f64 = |_| crash "can't encode F64"

encode_dec : Dec -> Encoder Attributes
encode_dec = |_| crash "can't encode Dec"

encode_bool : Bool -> Encoder Attributes
encode_bool = |_| crash "can't encode Bool"

encode_string : Str -> Encoder Attributes
encode_string = |str|
    Encode.custom |bytes, @Attributes { words }|
        if Str.is_empty str then
            bytes
        else
            escaped = escape (Str.to_utf8 str) [
                { needle: ['<'], replacement: ['&', 'l', 't', ';'] },
                { needle: ['&'], replacement: ['&', 'a', 'm', 'p', ';'] },
                { needle: ['"'], replacement: ['&', 'q', 'u', 'o', 't', ';'] },
            ]

            key = Str.join_with words "-"

            bytes
            |> List.concat [' ']
            |> List.concat (Str.to_utf8 key)
            |> List.concat ['=', '"']
            |> List.concat escaped
            |> List.concat ['"']

encode_list : List elem, (elem -> Encoder Attributes) -> Encoder Attributes
encode_list = |_, _| crash "can't encode List"

encode_record : List { key : Str, value : Encoder Attributes } -> Encoder Attributes
encode_record = |fields|
    Encode.custom |bytes, @Attributes fmt|
        List.walk fields bytes |acc, { key, value }|
            new_fmt = @Attributes { fmt & words: List.append fmt.words key }
            Encode.append_with acc value new_fmt

encode_tuple : List (Encoder Attributes) -> Encoder Attributes
encode_tuple = |_| crash "can't encode Tuple"

encode_tag : Str, List (Encoder Attributes) -> Encoder Attributes
encode_tag = |_, _| crash "can't encode Tag"

decode_u8 : Decoder U8 Attributes
decode_u8 = Decode.custom |_bytes, @Attributes _| crash "can't decode U8"

decode_u16 : Decoder U16 Attributes
decode_u16 = Decode.custom |_bytes, @Attributes _| crash "can't decode U16"

decode_u32 : Decoder U32 Attributes
decode_u32 = Decode.custom |_bytes, @Attributes _| crash "can't decode U32"

decode_u64 : Decoder U64 Attributes
decode_u64 = Decode.custom |_bytes, @Attributes _| crash "can't decode U64"

decode_u128 : Decoder U128 Attributes
decode_u128 = Decode.custom |_bytes, @Attributes _| crash "can't decode U128"

decode_i8 : Decoder I8 Attributes
decode_i8 = Decode.custom |_bytes, @Attributes _| crash "can't decode I8"

decode_i16 : Decoder I16 Attributes
decode_i16 = Decode.custom |_bytes, @Attributes _| crash "can't decode I16"

decode_i32 : Decoder I32 Attributes
decode_i32 = Decode.custom |_bytes, @Attributes _| crash "can't decode I32"

decode_i64 : Decoder I64 Attributes
decode_i64 = Decode.custom |_bytes, @Attributes _| crash "can't decode I64"

decode_i128 : Decoder I128 Attributes
decode_i128 = Decode.custom |_bytes, @Attributes _| crash "can't decode I128"

decode_f32 : Decoder F32 Attributes
decode_f32 = Decode.custom |_bytes, @Attributes _| crash "can't decode F32"

decode_f64 : Decoder F64 Attributes
decode_f64 = Decode.custom |_bytes, @Attributes _| crash "can't decode F64"

decode_dec : Decoder Dec Attributes
decode_dec = Decode.custom |_bytes, @Attributes _| crash "can't decode Dec"

decode_bool : Decoder Bool Attributes
decode_bool = Decode.custom |_bytes, @Attributes _| crash "can't decode Bool"

decode_string : Decoder Str Attributes
decode_string = Decode.custom |bytes, @Attributes _|
    match_remainder_of_string = |quote_char, rest|
        when List.split_first rest quote_char is
            Err NotFound -> { rest, result: Err TooShort }
            Ok { before, after } ->
                when Str.from_utf8 (escape before unescape_rules) is
                    Err _ -> { rest, result: Err TooShort }
                    Ok str -> { rest: after, result: Ok str }

    when bytes is
        ['"', .. as rest] -> match_remainder_of_string '"' rest
        ['\'', .. as rest] -> match_remainder_of_string '\'' rest
        _ -> { rest: bytes, result: Err TooShort }

decode_list : Decoder elem Attributes -> Decoder (List elem) Attributes
decode_list = |_elemDecoder|
    Decode.custom |_bytes, @Attributes _| crash "can't decode List"

RecordState state : { rest : List U8, state : state }

decode_record :
    state,
    (state, Str -> [Keep (Decoder state Attributes), Skip]),
    (state, Attributes -> Result val DecodeError)
    -> Decoder val Attributes
decode_record =
    |initial_state, step_field, finalizer|
        Decode.custom |bytes, fmt|

            parse_value : Str, RecordState state -> DecodeResult state
            parse_value = |key, { rest, state }|
                when step_field state key is
                    Skip ->
                        result = Decode.decode_with rest decode_string fmt
                        when result.result is
                            Ok _ -> { result: Ok state, rest: result.rest }
                            Err err -> { result: Err err, rest: result.rest }

                    Keep decoder ->
                        result = Decode.decode_with rest decoder fmt
                        when result.result is
                            Ok new_state ->
                                { result: Ok new_state, rest: result.rest }

                            Err _ -> result

            parse_attribute : RecordState state -> DecodeResult state
            parse_attribute = |{ rest, state }|
                when List.split_first rest '=' is
                    Err NotFound -> { rest, result: Err TooShort }
                    Ok { before, after } ->
                        when Str.from_utf8 before is
                            Err _ -> { rest: after, result: Err TooShort }
                            Ok key -> parse_value key { rest: after, state }

            loop : RecordState state -> DecodeResult state
            loop = |{ rest, state }|
                when skip_whitespace rest is
                    [] -> { rest, result: Ok state }
                    after ->
                        result = parse_attribute { rest: after, state }
                        when result.result is
                            Ok new_state ->
                                loop { rest: result.rest, state: new_state }

                            Err _ -> result

            when loop { rest: bytes, state: initial_state } is
                { rest, result: Err err } ->
                    { rest, result: Err err }

                { rest, result: Ok state } ->
                    {
                        result: finalizer state fmt,
                        rest,
                    }

decode_tuple :
    state,
    (state, U64 -> [Next (Decoder state Attributes), TooLong]),
    (state -> Result val DecodeError)
    -> Decoder val Attributes
decode_tuple =
    |_initial_state, _step_field, _finalizer|
        Decode.custom |_bytes, @Attributes _| crash "can't decode Tuple"

expect
    # Decode empty attribute list to empty record
    { result } = Decode.from_bytes_partial [] formatter
    result == Ok {}

expect
    # Decode string containing just whitespace to empty record
    { result } = Decode.from_bytes_partial [' ', '\n'] formatter
    result == Ok {}

expect
    # Decode multiple attributes
    { result } =
        Decode.from_bytes_partial
            (Str.to_utf8 " elm='leafy' \n pine=\"needly\" ")
            formatter
    result == Ok { elm: "leafy", pine: "needly" }

xml_whitespace : Set U8
xml_whitespace = Set.from_list [' ', '\t', '\n', '\r']

skip_whitespace : List U8 -> List U8
skip_whitespace = |bytes|
    List.drop_if bytes |byte| Set.contains xml_whitespace byte

expect
    result = skip_whitespace []
    result == []

expect
    result = skip_whitespace [' ', '\t', '\n']
    result == []

expect
    result = skip_whitespace [' ', '\t', '\n', 'a', 'b', 'c']
    result == ['a', 'b', 'c']
