# Guidance for AI coding agents

This file is for AI agents (Claude Code, Cursor, Codex, etc.) working in this
repository or with env files managed by dotenvxsh.

## Do not drive the TUI

`dotenvxsh.sh` is interactive-only: every prompt reads from `/dev/tty`, so
scripted or agent-driven input will hang. Use dotenvx directly instead — it is
non-interactive and encrypts on write:

```sh
dotenvx set KEY "value" -f <env-file>   # add or update (stores encrypted)
dotenvx get KEY -f <env-file>           # read a decrypted value
dotenvx encrypt -f <env-file>           # encrypt any plaintext values in the file
```

## Follow the naming schema

Entries written with raw `dotenvx set` must match the conventions the TUI
enforces. Naming follows `DOTENVXSH_NAMING_SCHEMA`:

- `suffix` (default): `<NAME>_API_KEY`, `<NAME>_PASSWORD`, `<NAME>_USER`
- `reverse`: `API_KEY_<NAME>`, `PASSWORD_<NAME>`, `USER_<NAME>`

Rules either way:

- Respect the user's configured schema when adding new keys; check the
  environment variable (unset means `suffix`)
- Credential pairs: always write both halves (password **and** user key); the
  TUI's pair display derives one name from the other
- Names are uppercase `A–Z`, `0–9`, and `_` only
- The TUI's search/update/show tolerate both orders, so existing entries in
  either schema remain accessible — do not rename existing keys to "fix" them

## Target files

- Local, per-project: `./.env`
- Global vault: `~/.config/credentials/credentials.env`, or the path in
  `DOTENVXSH_CREDENTIALS_FILE` if set

## Safety rules

- Never read, print, commit, or copy `.env.keys` — it holds the private
  decryption key.
- Never leave an env file decrypted on disk. If you must bulk-edit, run
  `dotenvx encrypt -f <file>` immediately afterwards.
- Never echo decrypted values into logs, commit messages, pull requests, or
  chat output.
- Before modifying an env file, ensure it is encrypted and commit that state
  (when it lives in a git repository), mirroring the script's own
  backup-before-write behaviour.
