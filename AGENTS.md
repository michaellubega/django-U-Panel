# Agent instructions (U-Panel)

## Git identity — required

**Never commit as Cursor Agent.** All commits must use the repository owner identity so Cursor does not appear on GitHub contributors.

Before the first `git commit` in every session, run:

```bash
./scripts/ensure-git-identity.sh
```

Or manually:

```bash
git config user.name "Michael"
git config user.email "michaeldieve@gmail.com"
```

Optional one-time setup (recommended on dev machines and Cloud Agent VMs):

```bash
./scripts/setup-git-hooks.sh
```

## Commit messages

- Do **not** add `Co-authored-by: Cursor` or any trailer mentioning `cursoragent@cursor.com`.
- Do not add redundant `Co-authored-by` lines when you are the sole author.

Git hooks strip Cursor co-author trailers automatically when hooks are enabled.
