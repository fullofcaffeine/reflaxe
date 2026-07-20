## Why

<!--
Explain the practical problem and why it belongs in the Reflaxe framework.
Lead with old behavior that a compiler author or user can observe.
-->

### Minimal Haxe reproduction

```haxe
// Required for behavior changes. Keep this as small as possible.
```

### Generated target consequence

Before:

```text
<!-- Show each relevant target language. Label simplified shapes honestly. -->
```

After:

```text
<!-- If the old compiler stopped before emission, show the exact diagnostic and phase instead. -->
```

## What

<!-- State the bounded behavior/API/tooling changes. -->

## How

<!-- Explain the ownership seam, important invariants, and why this design is target-neutral. -->

## Outcome

<!-- What can every affected Reflaxe compiler author rely on after this PR? -->

## Context

<!-- Link the incident, issue/Bead, request, or prior PR that exposed the need. -->

## Upstream Relationship

<!-- Record the upstream commit checked before work and how this fork differs. -->

## Reflaxe-Family Compatibility

<!-- Explain why this helps the compiler family and names no target-specific semantic policy. -->

## Behavior Changes

<!-- List generated output, lifecycle, API, diagnostics, cache, CI, or performance changes. -->

## Verification

<!-- Give exact commands, Haxe versions, negative tests, compatibility clients, and CI links. -->

- [ ] Focused framework regression passes.
- [ ] Declared Haxe matrix passes when relevant.
- [ ] Risk-routed family/integration canary passes when relevant.
- [ ] CI runs are linked; a missing run is not reported as passing.

## Risks And Rollback

<!-- Name plausible regressions, the last known-good fork commit, and the exact rollback path. -->

## Deferred Scope

<!-- State what this PR intentionally does not claim or close. -->

## Provenance Signature

<!-- Required for hxhx-agent changes; replace the placeholder with the actual incident. -->

```text
hxhx-agent created this because <plain-language incident and reason>.
```
