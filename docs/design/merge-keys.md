# Design: resolving merge keys (`<<`)

**Status:** implemented 2026-09-11. This note stays as the record of the
reference behaviour and the decisions taken; the code lives in
`Document.resolveMergeKeys`, `ParseOptions.resolve_merge_keys` and
`value.parseToValueResolved`.
**Author:** quiet-reef (dsh session). Reviewed by: —
**Tracking:** PLAN-16.

## Why

Merge keys (`<<: *base`, `<<: [*a, *b]`) are a YAML 1.1 extension that YAML
1.2 dropped; Kubernetes, GitLab CI, Ansible and Compose configs still use
them. yayl parses `<<` correctly as an ordinary plain scalar key whose value
is an alias, and README lists non-resolution as a deliberate v1 limitation.
That is the right *parse* — the bytes round-trip — but a consumer that reads
values gets a mapping with a literal `<<` entry instead of the merged keys,
and every consumer arriving from libfyaml or from K8s/GitLab hits it.

`tests/fixtures/gitlab-anchors.yaml` already carries three real `<<:` uses, so
the parse/round-trip/preservation gates pin the current behaviour; resolution
must be opt-in and must not change default output.

## What libfyaml does (the reference)

Two separate, both opt-in, implementations:

1. **Document path.** `FYPCF_RESOLVE_DOCUMENT` (parse flag, bit 2,
   `include/libfyaml/libfyaml-core.h:299`) makes document loading call
   `fy_document_resolve()` (`src/lib/fy-doc.c:3122`) after the tree is built.
   That function resolves anchors *and* merge keys in one pass: it inlines
   every alias, loops to a fixpoint, refuses reference loops first
   (`fy_check_ref_loop`), and purges all anchors at the end. It is also public
   as `fy_document_resolve`, so it can be called directly.
2. **Event path.** `fy_parser_event_resolve_hook_merge_key_start`
   (`src/lib/fy-parse.c:8747`) with `fy_parser_get_merge_key_document`
   (`:8625`) rebuilds a document from the recorded event stream. This is what
   the streaming resolve mode uses.

**Detection.** `fy_node_pair_is_merge_key` (`fy-doc.c:2744`): the pair key is
a scalar, style `plain`, atom text exactly `<<`. The parser primes the flag
when the atom bytes are `<<` and its length is 2 (`fy-parse.c:4901`, `:4945`);
a quoted `<<` is not a merge key, but a *plain* `<<` carrying an explicit
tag still is, because the check is style and text, not the tag.

**Value rules differ between the two paths.** This is a real libfyaml
inconsistency, not a misreading:

- document path (`fy_node_pair_is_valid_merge_key`, `fy-doc.c:2772`): the value
  must be an alias to a mapping, or a sequence whose *every* item is an alias
  to a mapping. A direct mapping value (`<<: {a: 1}`) is rejected.
- event path (`fy_parser_get_merge_key_document`, `fy-parse.c:8625`): accepts
  an alias, a direct mapping, or a sequence of aliases or direct mappings.
  This is closer to the YAML 1.1 merge-key text.

**Insertion and precedence** (`fy_resolve_merge_key_populate`, `fy-doc.c:2805`):
each source pair is deep-copied (`fy_node_copy`) and inserted *immediately
after* the `<<` pair, skipping a key that already exists in the target mapping
unless `FYPCF_ALLOW_DUPLICATE_KEYS` is set. Because insertion is "after the
`<<` pair", for `<<: [*a, *b]` the later source lands in front: **the first
alias in the sequence wins**, and an explicit key anywhere in the mapping
beats any merged key.

**Aftermath.** The `<<` pair is removed (`fy-doc.c:2921`). The outer loop
repeats resolution while the alias count keeps falling; a pass that does not
reduce it is an error. Duplicate keys created by resolution error with
"duplicate key after resolving" when duplicates are not allowed. Other
errors: "invalid merge key value", "invalid node type to use for merge key",
"invalid merge key sequence item (not an alias)", "merge key recursive alias
reference detected", "No recursive merge key processing is supported".

## What yayl has today

- `<<` is an ordinary plain scalar key; the value is an ordinary alias node.
  `Node.pairs()`, `Node.lookup()`, `Document.pathGet()` and
  `value.nodeToValue` all see the literal `<<` entry (and `nodeToValue` yields
  a `.mapping` pair keyed `<<`).
- Anchors live on nodes (`Node.anchor`, `src/document.zig:98`); the name-to-node
  table is the `Builder.anchors` map (`src/document.zig:1417`) and is transient
  — `Document` does not retain it. A resolve pass must rebuild it by walking
  the tree.
- Structural mutation is centralized: `Document.mappingAppend` /
  `sequenceAppend` attach and call `markModified` (`src/document.zig:753`),
  which flips the touched subtree to normalized emission. The faithful emitter
  reads `markup.Src` spans, so an inserted pair is emitted block-style rather
  than reproduced byte for byte.
- Value conversion already bounds alias expansion (`value.Limits`), and
  `edit.cloneTreeInto` shows how to copy anchors and retarget aliases into
  another subtree.

## Options considered

| # | Shape | Pros | Cons |
| - | ----- | ---- | ---- |
| A | Mutating pass on the parsed tree + `ParseOptions` flag | matches libfyaml; lookups and paths see merged data | normalizes emission for touched mappings |
| B | Resolve a clone, leave the original untouched | original stays byte-faithful | full copy; caller juggles two documents |
| C | Expand only during `value` conversion | smallest, non-mutating, bounded by `Limits` | `Document.lookup`/`pathGet` still do not merge, and it is a second rule implementation unless layered on A |
| D | Transparent merge in `lookup`/`pairs` | zero opt-in friction | changes round-trip, edit and duplicate semantics everywhere; rejected |

**Recommended:** one core rule (A), exposed three ways, so the rule lives in
exactly one place:

1. `Document.resolveMergeKeys() !void` — the pass itself, mutating, atomic
   (on error the document is unchanged), copying into the document pool.
2. `ParseOptions.resolve_merge_keys: bool = false` — runs the pass right after
   the document is built, matching `FYPCF_RESOLVE_DOCUMENT`.
3. A read-only convenience that clones, resolves and converts, for consumers
   that only want values.

This is deliberately merge-only: yayl already inlines aliases where it needs
to (`value`, `schema`), and there is no reason to widen this into the libfyaml
`resolve_document` and its anchor purge.

## Proposed semantics

- **Detection.** The raw key node is a scalar, style `.plain`, value `<<`. Do
  not follow aliases for the key; a quoted `<<` is not a merge key (a plain
  one with an explicit tag still is, matching libfyaml).
- **Values.** Alias-to-mapping, direct mapping, or a sequence of either — the
  YAML 1.1 rule (the libfyaml event path). This diverges from the libfyaml
  document path, so mark it with a `PORT NOTE`.
- **Precedence.** An explicit key anywhere in the target mapping wins over a
  merged key; among sources in a sequence, the earliest source wins. Equal key
  text is the comparison, matching how yayl reads keys.
- **Duplicates.** yayl keeps duplicate keys; the merge check skips a source key
  when any pair already in the mapping has the same key text (the libfyaml
  default with duplicates disallowed).
- **Nesting and recursion.** Resolve depth-first and to a fixpoint under a
  bound: a merged mapping may itself contain `<<`, and a source may be reached
  through an alias. A merge that reaches itself is `error.MergeKeyRecursive`.
- **Copying.** Deep-copy keys and values into the document pool with
  `cloneMergeNode`: strings are duped, spans and comments drop, and a copied
  node drops its own anchor so it cannot become a second definition of a name
  the source still anchors. Aliases are copied as aliases, so references stay
  valid. Anchors are never purged, unlike libfyaml.
- **Failure.** Any invalid value, non-mapping source, recursion or bound trip
  leaves the document byte-identical to before the call.
- **Bounds.** A single `max_merge_depth` (1000) caps both the walk and the
  copy, so a hand-built deep tree errors instead of overflowing the stack;
  parsed input is already capped by `max_nesting`.

## Decisions taken (2026-09-11)

All four recommended options were taken, and the work is implemented:

1. **Value rule: spec-permissive.** Inline mappings and sequences of them are
   accepted, matching the libfyaml event path and the YAML 1.1 text. The
   divergence from `fy_document_resolve` is marked with a `PORT NOTE`.
2. **Exposure: mutating pass + parse flag**, plus the parse-based read-only
   convenience. No clone-only `Document` variant was added; a caller holding
   a document calls `resolveMergeKeys` on it.
3. **Naming: `resolve_merge_keys` / `resolveMergeKeys`.** It resolves merge
   keys and nothing else — aliases are not inlined and anchors are not purged
   (unlike `fy_document_resolve`), so `resolve_document` would overstate it.
4. **Anchors on copies are dropped**, not the document's anchors. A copied
   node must not become a second definition of a name the source still
   anchors; the original anchor and every alias to it are untouched.

## What shipped

`Document.resolveMergeKeys` in `src/document.zig`, wired to
`ParseOptions.resolve_merge_keys` (parse and parseAll), plus
`value.parseToValueResolved`. Resolution runs on a same-document deep clone
(`edit.cloneTreeWhole`) and swaps it in only on success, so a failed resolve
leaves the document byte-identical; a document with no `<<` is returned
without a clone. The whole-tree clone refuses a forward alias
(`error.UnknownAlias`) rather than leaving a clone pointer at the pre-clone
tree, which would break that rollback; a test in `src/edit.zig` locks the
refusal and the subtree clone's legitimate outside-anchor fallback.

Unit tests in `src/document.zig` cover: an aliased source merged and the `<<`
key removed; explicit-key-wins; earliest-sequence-source-wins; inline mapping
and a sequence of inline mappings; a source that itself merges; a quoted `<<`
left as an ordinary key; invalid value and non-mapping sequence item refused
with `error.InvalidMergeKey`; a self-merge refused with
`error.MergeKeyRecursive`; a document without merge keys byte-identical; the
parse option and `parseAllOpts`; resolved output that re-parses; and
allocation-failure injection. `src/value.zig` covers the read-only path.

## Emitter bugs this surfaced

Two pre-existing emitter bugs were found by testing this feature and are
fixed on top of it, each with its own round-trip tests:

- a laid-out explicit key wrote `? K: V` on one line, which re-reads as a
  mapping key with a null value (fixed in `e91d04e`, found by the reviewer);
- structural line breaks hardcoded `\n`, so rewriting a mapping in a CRLF
  document lost the convention (`Emitter.defaultTerminator`).

## Still open

- Nothing. The two items that stood here — the libfyaml semantic
  differential and the unwired GitLab fixture — are closed; see
  "Semantic differential" below and the `gitlab-anchors.yaml` test in
  `src/document.zig`.
- The emission oracle now has a `merged` mode (resolve, then re-emit), so an
  independent parser checks the resolved output too: 816 documents across the
  three modes, 0 findings. It stays report-only in CI and is not part of
  `make verify`.

## Semantic differential (`make merge-differential`)

`scripts/merge-differential.sh` compares the VALUES yayl produces under
`resolve_merge_keys` against the values libfyaml produces under
`FYPCF_RESOLVE_DOCUMENT`, over `tests/fixtures/merge/`.

This is a different question from the emission oracle's `merged` mode.
That mode proves libfyaml can *parse* what yayl emits after resolution;
it cannot see a merge that picked the wrong source or dropped an entry,
because the wrong answer is still valid YAML. This gate sees exactly that:
inverting the sequence-source precedence turns it red on
`sequence-of-aliases.yaml` (`from-a` vs `from-b`).

Both sides emit the canonical, length-prefixed grammar documented at
`dumpCanonical` in `tests/emit.zig`. Three things are deliberately
normalized away, because neither library is wrong about them and none is
part of a document's value:

- **Anchors.** `fy_document_resolve` purges every anchor; yayl's merge is
  merge-only and keeps them.
- **Aliases**, which are followed on the yayl side. libfyaml inlines every
  alias while resolving, so following is what makes the two comparable.
- **Mapping entry order.** libfyaml puts merged entries before the
  mapping's own keys; yayl appends them. YAML mappings are unordered and
  the spec does not place merged entries, so the comparator sorts mapping
  entries by the key's own canonical dump — in one place, not in each
  dumper. Sequence order is *not* normalized: there, order is the value.

### Counted skips

PORT NOTE: yayl follows the permissive YAML 1.1 rule that libfyaml's
*event* path implements — a merge value may be a mapping directly, or a
sequence holding direct mappings. libfyaml's *document* path is stricter:
alias-only, and it rejects a mapping that repeats a key. Fixtures that
land on that divergence cannot be compared. They are named and counted in
the script's `UNCOMPARABLE` table and printed on every run, never skipped
silently — and each is still required to resolve under yayl, so a skip
can never hide a yayl failure.

| Fixture | Why it cannot be compared |
| --- | --- |
| `inline-mapping.yaml` | merge value is an inline mapping; libfyaml's document path is alias-only |
| `inline-in-sequence.yaml` | merge sequence holds inline mappings; same reason |
| `duplicate-merge-keys.yaml` | two `<<` entries in one mapping; libfyaml's document path rejects a repeated key |

The gate asserts a floor of 7 compared fixtures, for the same reason
`scripts/differential.sh` does: a gate that compared nothing must not
report success.
