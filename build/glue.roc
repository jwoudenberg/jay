app [makeGlue] {
    pf: platform "https://github.com/lukewilliamboswell/roc/releases/download/test/olBfrjtI-HycorWJMxdy7Dl2pcbbBoJy4mnSrDtRrlI.tar.br",
}

import pf.Types exposing [Types]
import pf.File exposing [File]

makeGlue : List Types -> Result (List File) Str
makeGlue = \types ->
    Ok [
        {
            name: "types.txt",
            content: List.map types Inspect.toStr |> Str.joinWith "\n",
        },
    ]
