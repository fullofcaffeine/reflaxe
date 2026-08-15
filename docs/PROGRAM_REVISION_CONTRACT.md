# Program Fingerprints and Stale-Plan Safety

## Practical outcome

Reflaxe gives each selected Haxe program a stable fingerprint. A fingerprint is
a content-based identifier, similar to a checksum. Targets can attach cached
compiler work to it and reject that work when the user program has genuinely
changed.

Unrelated macro work must not change this fingerprint. Real changes to the
selected program—such as changing an operator, type, field access, function
body, or retained declaration—must change it.

## The problem with Haxe's local numbers

Haxe's detailed typed-expression text includes a process-wide number for each
local variable. For example, this function:

```haxe
function total():Int {
	var value = 1;
	return value + 1;
}
```

might contain this internal text in one compiler process:

```text
[Var value(5378):Int]
[Local value(5378):Int:Int]
```

If unrelated macro code is typed first, the same function might instead use
`value(5380)`. The number changed because Haxe allocated two other locals; the
user function did not change.

Hashing those process-wide numbers directly caused false cache invalidation.
Generated target code and runtime behavior could remain identical while the
program fingerprint changed.

## What Reflaxe normalizes

Before hashing a function, Reflaxe walks the typed body in a documented
structural order. Each declaration receives an identity from:

- the function or body that owns it;
- its declaration role, such as argument, ordinary variable, or catch binding;
- its structural path through the typed expression; and
- its source name.

For example, the host numbers `value(5378)` and `value(5380)` both resolve to
the same lexical identity when they describe the same declaration in two
compiler processes. Two nested declarations both named `value` still differ
because their structural paths differ.

`LexicalLocalIdentityPlan` performs this walk. It keeps Haxe's number only in a
request-local lookup map so reads can be matched to declarations. The number is
replaced before a program revision, function-body revision, target plan, or
report can use it. Text inside a Haxe string literal is never interpreted as an
internal variable record.

Only the unstable number is replaced. The detailed typed expression still
records the facts that should invalidate cached work, including:

- operators and literal values;
- types resolved by Haxe, such as `Int` versus `Float`;
- the exact field or method selected by Haxe;
- control-flow and expression structure;
- metadata represented in the typed body;
- function signatures and declaration membership.

## Three identifiers with different jobs

Reflaxe deliberately keeps these identifiers separate:

| Identifier | Question it answers | Example reason to change |
| --- | --- | --- |
| Program revision | Is this the same selected Haxe program across requests? | A function body, type, field access, or retained declaration changed. |
| Function-body revision | Does a target record still describe this exact typed body and explicit replacement generation? | A preprocessor replaced or changed that body. |
| Target pipeline revision | Is this the same target implementation and configuration? | A target changed how it represents or generates an operation. |

A **target record** here means information a target calculated for later use.
For example, a target may record how to evaluate `items[nextIndex()]++` without
calling `nextIndex()` too many times. Reflaxe rejects that record if any
identifier it depends on no longer matches.

Normalizing local numbers does not weaken the stricter function-body check. The
body digest keeps the full normalized typed expression, and an explicit
generation counter advances whenever `ClassFuncData.setExpr` replaces the root,
including a structurally equivalent replacement. A target record tied to that
body still becomes stale when the body changes.

## Revision rollovers

The normalized program fingerprint uses program-revision schema 2. Moving from
schema 1 to schema 2 intentionally changes existing opaque fingerprint values
once, even for unchanged source. Targets must treat the value as an indivisible
cache key and must not parse it or depend on a particular hash.

Lexical-local identities use schema 1. Applying them to function-body revisions
also changes existing opaque body digests once. After those rollovers, unrelated
process-wide local-number changes no longer invalidate either revision.

This schema change must not alter generated target source or runtime behavior.

If a supported Haxe release changes its detailed local-variable format,
Reflaxe compares the number of local records in the typed body with the number
it normalized and stops with `reflaxe:unsupported-program-revision-renderer` on
a mismatch. It does not silently accept an unstable cache key.

## Target-author rules

- Use the program revision only for work that describes the selected Haxe
  program.
- Include the target pipeline revision when cached work also depends on target
  implementation or configuration.
- Use the exact function-body revision for information that must remain attached
  to one preprocessing result.
- Treat every revision value as opaque.
- Do not use source offsets, absolute paths, host object identity, or raw
  process-wide local numbers as durable identities.
- Fail before target source is emitted when a required revision does not match.

## Current boundary

The current upstream-Haxe adapter starts from Haxe's detailed typed-expression
text and normalizes the local numbers described above. A future native host,
including `hxhx`, must provide the same observable contract through its host
adapter: equivalent selected typed programs must produce equivalent normalized
facts without copying host object identity into the fingerprint.

This document does not define a serialized cross-host typed-expression format
or a universal intermediate representation. Those are separate architecture
decisions.

## Source and executable examples

- [`ProgramRevision.hx`](../src/reflaxe/lifecycle/ProgramRevision.hx) assembles
  the selected program fingerprint.
- [`LexicalLocalIdentityPlan.hx`](../src/reflaxe/lifecycle/LexicalLocalIdentityPlan.hx)
  maps request-local Haxe variables to stable lexical declarations.
- [`NormalizedProgramBodyDigest.hx`](../src/reflaxe/lifecycle/NormalizedProgramBodyDigest.hx)
  replaces renderer-local numbers through that plan before hashing.
- [`FunctionBodyRevision.hx`](../src/reflaxe/lifecycle/FunctionBodyRevision.hx)
  owns the stricter per-preprocessing-body identity.
- [`SemanticLifecycleTest.hx`](../test/SemanticLifecycleTest.hx) proves that
  unrelated local-number allocation is ignored while behavior, type, field
  access, and retained-module changes remain visible.
