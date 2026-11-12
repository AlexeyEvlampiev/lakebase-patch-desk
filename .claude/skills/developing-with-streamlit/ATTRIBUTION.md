# Attribution

This skill is a copy of Streamlit's own agent meta-skill. It is not changed.

| | |
|---|---|
| Source | https://github.com/streamlit/streamlit/tree/1.67.0/lib/streamlit/.agents/meta-skill/developing-with-streamlit |
| Publisher | Streamlit (Snowflake Inc.) |
| Version | Streamlit release tag `1.67.0`, commit `89f84a3a8abf0ca28226ad902c945c854e4a763a` |
| Read and copied | 2026-11-08 |
| Licence | Apache License 2.0, full text in [`LICENSE`](LICENSE) (copied from the root of `streamlit/streamlit` at the same tag) |
| Files | `SKILL.md`, `scripts/discover.py` |

The older home of this skill, `streamlit/agent-skills`, says it is
deprecated and points here.

## What it does

`SKILL.md` tells the agent to run `scripts/discover.py`. The script finds the
reference skill that ships inside the installed Streamlit package (1.57 and
later), matched to that version, and prints its path. The agent then reads
that skill. The guidance itself is not in this repo; it comes from the
Streamlit version the app installs.

## Safety check (2026-11-08)

- No network access. The only URL in the script is printed as a fallback
  for the agent to read; the script does not fetch it.
- It starts only two kinds of process: Python interpreters it finds for
  the project, each re-running this same file with `--probe`, which asks
  `importlib.util.find_spec("streamlit")` without importing Streamlit; and
  `poetry env info --path` when a `poetry.lock` exists. Children get
  `PYTHONDONTWRITEBYTECODE=1` and auto-install switched off, and each has a
  5-second limit.
- It writes no files, installs nothing and changes no environment.
- `SKILL.md` pre-approves only `python3`, `python` or `py -3` running this
  script (`allowed-tools`).

To update: copy both files from a newer Streamlit release tag, read the diff,
repeat this check and change the table above.
