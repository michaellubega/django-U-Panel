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

## Contabo environments (quick reference)

| | Production | Test |
|--|------------|------|
| URL | https://kiu.orion13.us | https://test.orion13.us |
| Path | `/opt/upanel` | `/opt/test` |
| Deploy | `deploy-web-on-server.sh` / compose prod | `deploy-test-on-server.sh` |
| Port | :80 (Cloudflare Flexible) | hostname via `upanel-edge` → `upanel-test-nginx:80`; host TEST_HTTP_PORT (default :8080; often :8085) for direct IP |

Details: `docs/SERVER_SETUP.md`, `docs/WEB_DEPLOYMENT.md`, `docs/CLOUDFLARE_DNS_SETUP.md`.
