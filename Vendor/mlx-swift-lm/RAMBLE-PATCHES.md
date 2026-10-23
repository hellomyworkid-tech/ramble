# Local changes to mlx-swift-lm 3.32.3

Copied from https://github.com/ml-explore/mlx-swift-lm at 3b339ad6e3b3f44c8121ecff5131c7fd55e075e6
(tag 3.32.3) and used by Ramble as a local package.

## Stable property order in guided generation

`Libraries/MLXFoundationModels/GuidedGeneration/SchemaConverter.swift`, `encodeToJSON`:
the JSON Schema handed to xgrammar is rewritten so object properties follow the
GenerationSchema's `x-order` (the order a `@Generable` type declares them) and all other
keys are sorted.

Why: `JSONEncoder` writes keys in a different order each call, and xgrammar makes the model
emit properties in that order. With the stock library, `OpenCaptureItem` was sometimes written
`title` before `type`, so the same sentence gave different records from one try to the next
(and every call missed the compiled-constraint cache).

When upgrading: check whether upstream now honours `x-order`; if not, re-apply this change.
