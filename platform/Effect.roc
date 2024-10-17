hosted Effect
    exposes [writePages, readPages]
    imports [Internal]

writePages : Box (List Internal.Pages) -> Task {} {}

readPages : Task (Box (List Internal.Pages)) {}
