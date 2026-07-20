# 🔐 dotenvxsh

Shell helper for faster processing of [dotenvx](https://dotenvx.com) files.

A small TUI script for adding, updating, and viewing secrets in dotenvx-encrypted
`.env` files — with automatic encryption, git-commit backups before every change,
and decrypted round-trip verification after every write.

![dotenvxsh session](assets/screenshot.svg)

## Prerequisites

- **[dotenvx](https://dotenvx.com)** — the encrypted `.env` toolkit this script drives.
  Download from [dotenvx.com](https://dotenvx.com) or [github.com/dotenvx/dotenvx](https://github.com/dotenvx/dotenvx):

  ```sh
  # macOS (Homebrew)
  brew install dotenvx/brew/dotenvx

  # or the install script
  curl -sfS https://dotenvx.com/install.sh | sh
  ```

- **bash** ≥ 3.2 (works with the stock macOS bash) and standard Unix tools.
- **git** *(optional)* — when the target env file lives inside a git repository,
  pre-change backups are taken as commits; otherwise a timestamped `.bak` copy
  is made next to the file.

## Installation

```sh
git clone https://github.com/GavinTomlins/dotenvxsh.git
cd dotenvxsh
chmod +x dotenvxsh.sh
```

Optionally symlink it onto your `PATH`:

```sh
ln -s "$PWD/dotenvxsh.sh" /usr/local/bin/dotenvxsh
```

## Usage

```sh
./dotenvxsh.sh               # interactive file picker
./dotenvxsh.sh path/to/.env  # target a specific file, skipping the picker
```

With no argument, the script first asks which env file to work on:

```
Which env file?
  1) ./.env (current directory)
  2) ~/.config/credentials/credentials.env
```

Choosing option 2 creates `~/.config/credentials/` on first use, giving you a
central, encrypted credentials vault usable from any project.

### Menu

```
  1) 🔑 API_KEY          (adds <NAME>_API_KEY)
  2) 👤 USER & PASSWORD  (adds <NAME>_PASSWORD and USER_<NAME>)
  3) ✏️ Update API_KEY   (search & update a *_API_KEY)
  4) ✏️ Update PASSWORD  (search & update a *_PASSWORD)
  5) 🔍 Show API_KEY     (search & display a *_API_KEY)
  6) 🔍 Show USER & PASSWORD (search & display *_PASSWORD + USER_*)
  q) Quit
```

**1 — Add an API key.** Prompts for a name and builds `<NAME>_API_KEY`
(input is uppercased, and anything that isn't a letter, digit, or underscore
becomes an underscore — `some system` → `SOME_SYSTEM_API_KEY`). The value is
entered hidden.

**2 — Add a user & password pair.** One name produces both variables:
`<NAME>_PASSWORD` and `USER_<NAME>` (e.g. `AIHUB` → `AIHUB_PASSWORD` and
`USER_AIHUB`). If one half of the pair already exists, it is skipped and the
other is still added.

**3 / 4 — Update.** Type a search term (case-insensitive substring — `gitlab`
finds `GITLAB_API_KEY` and `GITLAB_CI_API_KEY`). A single hit goes straight to
the hidden value prompt; multiple hits are presented as a numbered picker.
Every step can be cancelled: empty search input, `c` in the picker, or an empty
value all abort with the file untouched.

**5 / 6 — Show.** Same search flow, then the value is decrypted with
`dotenvx get` and printed. Option 6 collapses `USER_FOO` / `FOO_PASSWORD`
matches into one logical credential and displays both halves of the pair,
warning if either half is missing.

### What happens on every write

1. **Duplicate check** — a key that already exists is never re-added.
2. **Encrypt** — `dotenvx encrypt` runs first, so the file is fully encrypted
   before anything else touches it.
3. **Backup** — the encrypted file is committed to git (or copied to a
   timestamped `.bak` when not in a repository).
4. **Write** — the new value is appended (or set, for updates) and encrypted.
5. **Round-trip check** — the value is decrypted with `dotenvx get` and echoed
   back so you can confirm it stored correctly.

No manual decryption is ever needed: dotenvx uses public-key encryption, so
new values are encrypted with the `DOTENV_PUBLIC_KEY` already in the file.

### Consuming the secrets

```sh
# inject decrypted values straight into a command's environment
dotenvx run -f ~/.config/credentials/credentials.env -- some-command

# read a single value
dotenvx get GITHUB_API_KEY -f ~/.config/credentials/credentials.env
```

## Security notes

- `dotenvx encrypt` writes the private decryption key to `.env.keys` beside the
  env file. **Never commit `.env.keys`** — this repository's `.gitignore`
  excludes it, and the script's backup commits only ever include the env file
  itself.
- The round-trip check and the show options print decrypted secrets to your
  terminal (and therefore scrollback). Avoid using them while screen-sharing.

## License

[MIT](LICENSE)
