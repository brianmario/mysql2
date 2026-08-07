# Toolchain setup (this machine)

This machine uses **MacPorts, not Homebrew**. `gh`, `mise`, and other CLI
tools live under `/opt/local/bin` and `/opt/local/sbin`. Don't suggest
`brew install` for anything here — use `port install <name>` if a tool is
genuinely missing, but check `which -a <tool>` first since more is already
installed than you might expect.

There is no rbenv/chruby/rvm/asdf on this machine. Ruby version management
is via **mise** (`port install mise` if `which mise` comes up empty).

## Ruby / MySQL for this repo

`mise.toml` at the repo root pins the toolchain:

```toml
[tools]
mysql = "latest"
ruby = "3.3"
```

If that file is missing (it's intentionally left untracked in this repo —
don't `git add` it, don't remove it if you find it in your worktree, it's
gitignored-by-convention rather than by `.gitignore`), recreate it with the
content above, then run `mise install`.

**Known gotcha**: in this environment, `mise exec -- <cmd>`, and even
`eval "$(mise env)"`, do not reliably take effect — the system Ruby
(`/usr/bin/ruby`, 2.6.x) keeps winning because of how PATH is already
laid out before mise's entries. The one thing that reliably works is
exporting PATH by hand, prepending mise's actual install directories.
Find the exact paths once with:

```bash
mise which ruby   # -> .../installs/ruby/<version>/bin/ruby
mise which mysqld # -> .../installs/mysql/<version>/bin/mysqld (or use `mise ls`)
```

Then, at the top of every Bash tool call in a session (shell state does not
persist between calls), do:

```bash
export PATH="$(dirname "$(mise which ruby)"):$(dirname "$(mise which mysqld)"):$PATH"
```

or hardcode the versioned paths once you've resolved them, e.g.:

```bash
export PATH="/Users/aaron/.local/share/mise/installs/ruby/3.3.7/bin:/Users/aaron/.local/share/mise/installs/mysql/8.0.34/bin:/Users/aaron/.local/share/mise/installs/mysql/8.0.34/scripts:$PATH"
```

Verify with `ruby -v` (should show 3.3.x, not 2.6.x) and `which bundle`
(should resolve under the mise ruby's `bin/`, with bundler 2.5.x) before
running `bundle install` / `bundle exec`.

## Building and testing

```bash
bundle install
bundle exec rake compile
bundle exec rspec                 # needs a running MySQL, see below
bundle exec rubocop               # or: bundle exec rake rubocop
```

## Standing up a local MySQL for specs

`spec/configuration.yml` expects a server on `127.0.0.1:3306` with a
`root`/`root` account and a `test` database. There is normally nothing
running on 3306 on this machine. To stand one up from mise's installed
MySQL, using the session's scratchpad directory for the data dir (socket
paths have a ~103-char OS limit, so the socket itself must live somewhere
short, e.g. `/tmp`, even though the data dir can be under the scratchpad):

```bash
DATADIR=/path/to/some/writable/dir/mysql-data   # e.g. your scratchpad
mkdir -p "$DATADIR"
mysqld --no-defaults --initialize-insecure --datadir="$DATADIR" \
  --basedir="$(dirname "$(dirname "$(mise which mysqld)")")"

mysqld --no-defaults --datadir="$DATADIR" \
  --basedir="$(dirname "$(dirname "$(mise which mysqld)")")" \
  --socket=/tmp/mysql2-test.sock --pid-file=/tmp/mysql2-test.pid \
  --port=3306 --bind-address=127.0.0.1 > /tmp/mysqld.log 2>&1 &
disown
sleep 3

mysql -h127.0.0.1 -P3306 -uroot -e \
  "ALTER USER 'root'@'localhost' IDENTIFIED BY 'root'; CREATE DATABASE IF NOT EXISTS test;"
mysql -h127.0.0.1 -P3306 -uroot -proot -e \
  "CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY 'root'; GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION; FLUSH PRIVILEGES;"
```

(The two-step user setup is because a TCP connection to `127.0.0.1` needs a
`'root'@'127.0.0.1'` grant specifically — `'root'@'localhost'` alone won't
match it.)

Shut it down when done: `mysqladmin -h127.0.0.1 -P3306 -uroot -proot shutdown`.

## GitHub CLI

`gh` is at `/opt/local/bin/gh` (MacPorts), already on PATH. If it reports
not logged in, that's an auth gap, not a missing-tool problem — don't try
to reinstall it.
