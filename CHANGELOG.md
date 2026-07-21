# Changelog

All notable changes to dotenvxsh are documented here, in human terms.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Each commit's mandatory `Changelog:` trailer (`added`, `fixed`, `changed`,
`deprecated`, `removed`, `security`, `performance`, `other`) says which section
its change belongs in.

## [Unreleased]

### Added

- Interactive TUI (`dotenvxsh.sh`) for managing secrets in dotenvx-encrypted
  env files. Add API keys as `<NAME>_API_KEY`, or user/password pairs as
  `<NAME>_PASSWORD` plus `USER_<NAME>`, with hidden value entry and duplicate
  protection.
- Search-driven **update** and **show** options: find keys by case-insensitive
  substring, pick from a numbered list when there are multiple matches, and
  cancel safely at any step. Show collapses a credential pair into one entry
  and displays both halves.
- Whole-file **encrypt** and **decrypt** menu options. Decrypt warns, requires
  explicit confirmation, and backs up the encrypted state first.
- Safety net around every write: the file is encrypted first, backed up as a
  git commit (or a timestamped `.bak` copy outside a repository), and the new
  value is decrypted back with `dotenvx get` as a round-trip check.
- File picker offering the local `./.env` or a global credentials vault at
  `~/.config/credentials/credentials.env`, with the vault location
  configurable via the `DOTENVXSH_CREDENTIALS_FILE` environment variable.
- Documentation: README with prerequisites, installation, usage for every menu
  option, local vs global configuration, and security notes; `AGENTS.md` with
  non-interactive guidance and safety rules for AI coding agents.
