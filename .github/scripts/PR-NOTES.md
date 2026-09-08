Related: #167, #85

This branch introduces a REST-only release check-status helper and regression coverage. The production workflow still needs its three GraphQL `statusCheckRollup` polling loops wired to the helper before merge.
