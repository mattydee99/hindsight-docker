# Feature request: a way to (re)build the entity layer over existing facts without re-extracting them

## Summary

There is currently no supported way to populate/rebuild a bank's entity layer (`entities`, `unit_entities`, `entity_cooccurrences`) from facts that **already exist**. The only route that re-attaches entities to stored facts is `POST /documents/{id}/reprocess`, which deletes the document's memory units and **re-extracts the facts** from source content. That's a heavy, lossy operation to run when all you actually want is to (re)derive the entity graph from facts whose entity information is already present.

I'd like a lightweight operation — e.g. `POST /banks/{bank_id}/entities/reresolve` or an admin CLI `reresolve-entities` — that runs the existing `EntityResolver` over existing memory units and skips fact extraction entirely.

Tested on **v0.8.4**.

## Motivation / concrete scenario

Several ordinary config changes leave every *existing* fact with no entity links, and no cheap way to fix them retroactively:

1. **Flipping `entities_allow_free_form` from `false` → `true`.** In labels-only mode the post-extraction step (`engine/retain/fact_extraction.py`, ~L1513–1519) strips all non-label entities, so `unit_entities` stays empty and the canonical `/entities` table never grows. After turning free-form back on, only *new* retains populate entities — the entire history is stranded.
2. **Changing the extraction model** to one that populates the `entities` field where the previous one didn't.
3. **Adding or fixing `entity_labels`** on a bank with existing content.

In all three cases the facts themselves are fine and unchanged — they already carry the entity information (the `who` / "Involving:" content is right there in the fact text). Re-running fact extraction just to recover entities is redundant work.

## Why `reprocess` isn't the right tool

`reprocess` "deletes the existing memory units and re-extracts facts using the current engine configuration." For an entity backfill that means:

- **Redundant LLM cost + latency** — re-extracting facts that already exist, purely to get entities that are already in the fact text.
- **Mutates existing memory** — facts are regenerated; under a different model the fact set changes, so the operation is not idempotent across models. Users backfilling entities usually do **not** want their historical facts rewritten.
- **Churns unit IDs, links, and consolidation** — deleting and recreating memory units disturbs `unit_entities`, temporal/semantic/causal links, and triggers consolidation, when the goal was only to add the entity layer.

`entities/{id}/regenerate` is deprecated (returns 410), and `graph_maintenance` only *prunes* orphaned entities — neither creates them.

## Proposed solution

A dedicated re-resolve operation that reuses the machinery retain already has (`_pre_resolve_phase1` → `entity_processing.resolve_entities` → `EntityResolver.resolve_entities_batch` → `link_units_to_entities_batch` + cooccurrence stats), but sourced from **stored units** instead of freshly-extracted facts:

```
POST /v1/default/banks/{bank_id}/entities/reresolve
```

Behavior:

- Iterate existing memory units for the bank (optionally scoped by `document_id`, tag, or date range).
- Derive entity mentions **without re-extracting facts**. In order of preference:
  - **(a)** an entity-only LLM pass over each fact's text (cheap — no full fact schema, no chunking), or
  - **(b)** parse the entity mentions the fact already encodes (the `who` field), or
  - **(c)** accept caller-supplied `{unit_id: [entities]}`.
- Run the existing `EntityResolver` to resolve/create canonical entities, insert `unit_entities`, and record `entity_cooccurrences`, honoring the bank's `entity_labels` / `entities_allow_free_form` config.
- Leave facts, unit IDs, and non-entity links untouched.
- Idempotent — `bulk_insert_unit_entities` already uses `ON CONFLICT DO NOTHING`; re-runs should be safe.
- Set `first_seen`/`last_seen`/`last_cooccurred` from each fact's event date, not the backfill moment (retain already does this).

Nice-to-haves: a `dry_run` that reports how many entities/links *would* be created; batch/streaming for large banks; an admin CLI equivalent for offline bulk runs.

## Acceptance criteria

- Running the op on a bank whose facts have empty `entities` populates `/entities`, `unit_entities`, and `entity_cooccurrences` **without deleting or altering any fact or memory unit**.
- No fact-extraction LLM calls when using source (b)/(c); an entity-only pass when using (a).
- Re-running the op is idempotent (no duplicate entities/links, no double-counted `mention_count`).
- Respects `entity_labels` and `entities_allow_free_form`.

## Workarounds today (for reference)

- `reprocess` every document — works, but re-extracts facts (cost, mutation, churn).
- `export-bank` → script-fill each fact's `entities` field from its text → `import-bank` — avoids fact re-extraction, but is fiddly and risks duplicate-import conflicts on a live bank.
- Direct DB inserts — bypasses the resolver's invariants; unsafe.

None of these is a good fit for "I just changed a config flag; please backfill the entity graph from facts I already have."
