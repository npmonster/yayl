# Design: making comments addressable

**Status:** proposal, awaiting human approval. Workstream B1 of PLAN-12.
**Author:** vast-wren. Reviewed by: —

## The problem

yayl's headline is comment preservation. A consumer cannot read a node's
comment, or add, change, or remove one.

Comments survive because they are never claimed by anything. `emitPair`
and `emitItem` receive the offset where an entry's leading *gap* begins
and return where the next gap starts; `writeGap` copies those bytes
verbatim, minus tombstones for deleted entries (`src/emitter.zig`). A
comment is simply source between two entries that no node points at.
`markup.Src` is `{ entry_start, start, end, synthetic }` — offsets, no
comment field — and `Node` has no comment member.

That is why the preservation guarantee is so strong and why the API is
so weak: nothing has to *understand* a comment to keep it. The moment
something addresses one, that changes.

The concrete miss: a tool that edits a config and wants to annotate the
key it just changed — the most obvious use of a comment-preserving YAML
library — cannot.

## Why this is a design change, not a feature

Comment spans would live in `markup.Src`, and those spans are the
mechanism the byte-faithful round trip is built on. The risk is not that
a comment API is hard to write; it is that a careless one puts the
product's central guarantee at risk, and that guarantee is the reason to
choose this library.

So the proposal splits along the line where that risk changes character.

## Phase 1 — reading (safe by construction)

**Claim: the read half cannot affect emission at all.**

Emission copies gap bytes verbatim. If reading only *describes* bytes
the emitter already copies — computing spans, never storing new ones
that emission consults — then no emitted byte can change. That is not a
promise to be tested for so much as a property of not touching the
write path; the corpus round trip stays green because nothing in it ran
differently.

Two comment positions are worth exposing first, because both are
already unambiguous in the source:

- **Trailing** — same line, after the value. `markup.remainderHasComment`
  already exists and its doc comment records why a byte scan is exact:
  *"Everything between a node's content end and its line terminator can
  only be blanks and a comment (the grammar guarantees no other token
  can follow there)."* The read is `src.end` → `markup.newlineAt`.
- **Leading** — own-line comments immediately above an entry, with no
  blank line between them and it. Scan back from `entry_start` over
  whole lines while each is blank-prefixed then `#`. Stopping at a blank
  line is the rule that makes "belongs to this entry" decidable.

Proposed surface, returning slices into `Document.source` — no
allocation, so no ownership question:

```zig
pub fn trailingComment(self: *const Node, doc: *const Document) ?[]const u8
pub fn leadingComments(self: *const Node, doc: *const Document) ?[]const u8
```

Open question for review: `#` and the leading blank included, or
stripped? Raw is honest and lossless; stripped is what a caller usually
wants. Recommendation: return raw, and add `commentText()` later if it
proves annoying — the reverse is a breaking change.

A node built rather than parsed has no `src` and returns null. So does a
node whose comment was consumed by a neighbouring entry's gap, which is
why phase 1 ships with a test that every comment in every fixture is
reachable from *some* node: not a proof of correctness, but a check that
the attachment rules leave nothing orphaned.

## Phase 2 — writing (where the guarantee is at stake)

A comment that did not exist has no source bytes, so it has to be
synthesised into a gap the emitter currently copies whole. That is the
hard part, and it is why this is a separate release with its own gate
work rather than the second half of one commit.

```zig
pub fn setTrailingComment(self: *Document, node: *Node, text: ?[]const u8) !void
pub fn setLeadingComments(self: *Document, node: *Node, text: ?[]const u8) !void
```

Null deletes. Both mark the node modified, so its slot re-emits rather
than being copied — which means the *rest* of the gap has to be
reconstructed rather than sliced, and that is exactly the code path
where a mistake silently drops a neighbour's comment.

The invariant that makes this testable is the one the preservation
sweep already uses for scalars: **setting a comment to the text it
already has must be byte-identical.** The sweep grows comment positions
and asserts it. That single property catches the whole class — if
re-writing an unchanged comment perturbs one byte of its surroundings,
the sweep says so, at every position in every fixture.

## Questions this design does not settle

These need answering before phase 2, and reviewers should push back:

1. **Ownership.** A trailing comment on `port: 8080 # user facing`
   belongs to the *pair*, not to the scalar `8080`. The proposal
   attaches to the node and lets the pair's value stand in for the pair,
   which reads naturally and is wrong in at least one case: a comment
   after a key but before its value.
2. **Free-floating comments** — blank-line-separated blocks belonging to
   no entry, and a comment after a container's last entry. Recommended
   out of scope for phase 1: they are addressable only relative to a
   container, which is a different API shape.
3. **Fate under edits.** Once a consumer can hold a comment, "what
   happens when its entry is deleted or moved" has to be *stated*.
   Today it is implicit in byte ranges: deleting an entry removes its
   whole line including the trailing comment, and a moved subtree loses
   its internal comments. Both are documented limitations; a comment API
   makes them promises instead of side effects.
4. **Flow collections and CRLF.** The preservation sweep already counts
   both as skip categories in places. A comment API must not quietly
   widen what it claims to support.

## Explicitly out of scope

- Comment reflow, re-wrapping, or normalisation of `#` spacing.
- Preserving comments inside a **moved** subtree — a harder, separate
  problem, already a documented limitation.
- Comments in flow collections for phase 1.

## Acceptance

Phase 1: every comment in every fixture reachable from some node;
conformance 351/351, round trip 265/4, preservation zero failures,
differential 269/0 — all unchanged, because nothing in emission ran.

Phase 2: the preservation sweep extended to comment positions with
set-to-same-comment asserted byte-identical; all baselines held; the
README limitation "Comments are preserved, not addressable" deleted
rather than reworded.
