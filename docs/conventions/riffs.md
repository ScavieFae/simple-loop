# Riffs

Riffs are exploratory thinking blocks embedded in markdown. They capture speculative ideas, half-formed hypotheses, things that might be wrong. They are not polished arguments — they're clay.

## Block grammar

```html
<!-- riff id="unique-id" status="draft|developing|tested" could_become="tweet, blog, talk, brief, spec" -->
Content of the riff. Speculative, might be wrong.
<!-- /riff -->
```

### Attributes

- **id** — unique within the document. Kebab-case. Used to reference the riff externally.
- **status** — lifecycle stage:
  - `draft` — first pass, not yet stress-tested
  - `developing` — multiple revisions, gaining conviction
  - `tested` — validated against reality; usually a step away from a spec or decision
- **could_become** — where this might land if it survives: `tweet`, `blog post`, `talk`, `brief`, `ADR`, `spec`

## Convention

- **Don't clean up riff blocks.** They are load-bearing context even when they look messy. Their messiness signals they're still in process.
- **Don't move riff content out of the block** unless it graduates to an ADR, spec, or doc. The block is the canonical home until then.
- **Do update `status`** as the idea develops.
- **Do add `<!-- /riff -->`** closing tag. Unclosed blocks cause rendering issues.

## Graduation path

`draft` → `developing` (after pushback + revision) → `tested` (after validation) → **graduate to ADR, spec, or doc** (remove the riff block, write the stable artifact).

A riff that stays `draft` forever is a parking lot, not a thinking tool. Either develop it or delete it.
