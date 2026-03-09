---
name: update-trouble
description: Append an entry to TROUBLESHOOTING.md — document bugs encountered and how they were resolved
---

# Update TROUBLESHOOTING.md

Append a new entry to `TROUBLESHOOTING.md` at the top of the file (below the header). Write to this every time you encounter a bug that requires investigation to resolve.

## Entry format

```markdown
## [Date] — [Symptom in plain language]

**Symptom:** [What you observed. Error messages, unexpected behavior, test failures.]

**Investigation:** [What you checked. What you ruled out. The trail you followed.]

**Root cause:** [What was actually wrong.]

**Fix:** [What you did to resolve it. Reference specific files/commits.]

**Prevention:** [Optional. How to avoid this in the future, if applicable.]
```

## Rules

- **Always append, never edit or delete existing entries.** TROUBLESHOOTING.md is append-only.
- **Write when you go on a quest.** Quick fixes don't need entries. If you had to investigate — search logs, read stack traces, try multiple approaches — document it.
- **Include the investigation trail.** What you ruled out is as valuable as what you found. It saves the next person from re-checking.
- **Be specific about symptoms.** "Test failed" is useless. "test_auth.py::test_token_refresh fails with 401 on line 47" is useful.
- **This is institutional memory.** The same bug class will recur. This file is how we stop solving the same problem twice.
