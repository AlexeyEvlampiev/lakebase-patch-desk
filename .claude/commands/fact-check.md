---
description: "Check the platform claims in one file against their evidence (read-only). Prints a table: claim, evidence, status (verified, UNVERIFIED, stale, missing). Arg: the file to check."
argument-hint: "<file> — the file to check, e.g. README.md"
disallowed-tools: Write Edit NotebookEdit Bash
allowed-tools:
  - Read
  - Grep
  - Glob
  - WebFetch
  - mcp__plugin_context7_context7__resolve-library-id
  - mcp__plugin_context7_context7__query-docs
---

Fact-check `$ARGUMENTS` under the grounding rule in `CLAUDE.md`. This
command only reports. It changes no file; a person or an agent
fixes what it finds.

1. **Read the file** `$ARGUMENTS` and `docs/sources.md`. With no argument,
   say "Usage: /fact-check <file>" and stop.
2. **List the platform claims.** A platform claim is a statement about how
   Databricks, Lakebase, Databricks Apps, Asset Bundles, Unity Catalog,
   PostgreSQL or another vendor tool behaves, costs or is configured.
   Statements about this repo's own design or code are not claims here.
3. **Find the evidence for each claim**, in this order:
   - a link next to the claim in the file, with a date read nearby;
   - an entry in `docs/sources.md` that backs it (URL, date read).
   Evidence is a public URL or a `docs/sources.md` entry, never a private
   path.
4. **Give each claim a status**, using today's date:
   - `verified`: evidence found, read 30 days ago or less;
   - `stale`: evidence found, read more than 30 days ago, or with no date;
   - `UNVERIFIED`: the file itself marks the claim `UNVERIFIED:`;
   - `missing`: no evidence found.
   Do not fetch the docs to upgrade a status. If asked, a separate step may
   fetch a source and say what changed.
5. **Print one table** and a one-line count:

   | # | Claim (short) | Line | Evidence | Status |
   |---|---|---|---|---|

   `N claims: V verified, S stale, U UNVERIFIED, M missing.`

   Then list what to do for each `stale` and `missing` claim, in one line
   each: add a source, re-read it, or drop the claim.
