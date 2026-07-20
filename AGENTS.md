# Agent Instructions

## Newcomer-Friendly Technical Writing

Use the globally installed `$explain-technical-work` Codex skill when it is
available and you draft or revise a substantial pull request, commit body,
issue, design document, status report, or handoff. The rules below remain the
repository-local contract when the skill is unavailable.

Assume the reader understands Haxe and ordinary software development but has
not studied this repository's compiler internals.

- Lead with the practical old behavior, the problem it caused, the new
  behavior, and any important limitation. Internal filenames and type names
  support that explanation; they do not replace it.
- Define specialized terms on first use, including ordinary words used in a
  narrower local way. A definition should say what the term means here, why it
  matters, and give a small example when useful.
- Expand compressed labels and noun stacks into ordered actions. Introduce the
  short internal name only after those actions are clear.
- Connect a minimal Haxe example to real generated target code or observable
  behavior. If compilation stopped before output, show the real diagnostic and
  say explicitly that no target code was produced.
- Link the most useful primary reference: public API documentation, the source
  contract, an architecture decision, or a focused test. A link supplements
  the explanation; it does not substitute for one.
- Preserve technical precision. Do not hide limitations, imply broader target
  support, or turn an internal milestone into a user-ready claim merely to make
  the writing simpler.

Before publishing, apply this first-read test: a capable Haxe developer new to
Reflaxe should understand why the change matters and what behaves differently
before they need to follow an internal symbol link.
