module [okOrCrash, storedPages]

import Effect
import Internal

okOrCrash : Task a * -> Task a *
okOrCrash = \task ->
    Task.attempt
        task
        (\result ->
            when result is
                Ok x -> Task.ok x
                Err _ -> crash "OH NOES"
        )

storedPages : {} -> Task (List Internal.Pages) *
storedPages = \_ ->
    Task.attempt! (Effect.readPages) \result ->
        when result is
            Ok pages ->
                Task.ok (Box.unbox pages)

            Err _ ->
                Task.ok []
