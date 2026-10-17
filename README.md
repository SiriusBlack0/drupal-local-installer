# Drupal Local Installer

Interactive Bash installer that creates local Drupal projects on Ubuntu
(native or WSL). It asks a few questions, checks the system, installs what
is missing (only after you approve), and creates the project with the
correct PHP version.

> **Status:** work in progress. The installer creates a working Drupal
> site at `http://<project>.localhost`: project files (Drupal + Drush),
> database, PHP-FPM pool, Nginx site and `drush site:install`. Removing
> and updating projects come next. See [Roadmap](#roadmap).

## Requirements

- Ubuntu (native, or WSL with or without systemd)
- A normal user with `sudo` rights. Do **not** run the installer as root.
- Internet access (APT packages, Composer/Packagist)

## Usage

```bash
./install.sh            # normal run
./install.sh --step     # pause before each installation step
./install.sh --verbose  # show the full output of every command
./install.sh --help
```

The installer works in three phases:

1. **Questions** – project name, Drupal version, PHP version, database,
   administrator password.
   Nothing is changed on the system.
2. **Checks** – existing project, directory, Nginx config, packages,
   PHP extensions, services. Nothing is changed on the system.
3. **Installation** – only after you confirm: missing packages (with a
   simulation and a second confirmation first; a database server that is
   not installed yet is included, and the installer never removes a
   package – for example MySQL is refused while MariaDB is installed,
   because one would replace the other), project directory,
   project directory, database, PHP-FPM pool, Nginx site, then Drupal and
   Drush (Composer), then `drush site:install`.
   The sudo password is asked once, right after you confirm.

Why this order: Composer runs `sudo -K` every time it starts, on
purpose. It forgets your cached sudo password so that scripts from the
packages it downloads cannot use it. The installer respects that: all
work that needs sudo is done **before** Composer, and Composer, Drush and
`site:install` run as your normal user. (Only if something fails after
Composer, the rollback asks for the sudo password again.)

## Supported versions

Supported Drupal releases and their PHP and database requirements are
listed in [`config/compatibility.conf`](config/compatibility.conf), taken
from the official drupal.org requirement pages.

- Only PHP versions that are installed, or installable from your package
  sources, can be selected.
- Older Drupal releases (no longer supported by drupal.org) are refused.
  For those, a container-based setup (for example DDEV) is recommended.

## What a project looks like

```
/var/www/<project>/                  owner: you, group: www-data, mode 2750
├── composer.json, vendor/, web/     Drupal (drupal/recommended-project)
├── start                            starts the services this project needs
├── drush                            runs Drush with the project PHP
├── composer                         runs Composer with the project PHP
├── private/database.sqlite          SQLite only, outside the web root
└── .drupal-local-installer/bin/php  link to the project PHP version
```

### Starting a project

```bash
/var/www/<project>/start
```

`./start` starts the services the project needs: PHP-FPM for the
project PHP version, Nginx, and the database server (none for SQLite).
Services that are already running are left alone, and nothing is ever
stopped, because other projects may use the same services. It works
with and without systemd, which makes it useful on WSL, where services
often do not start on their own.

It also makes sure the project itself is loaded. If PHP-FPM or Nginx were
already running when the project was created and the project's pool
socket is missing or the site does not answer as Drupal, `./start`
checks the configuration (`php-fpmX.Y -t`, `nginx -t`) and only then
**reloads** the service. A reload loads new configuration without
dropping the other projects; a restart is never used.

## Project registry

After a successful installation the project is recorded in

```
~/.local/share/drupal-local-installer/projects/<project>.conf
```

(directory 700, file 600, owned by you). It lists everything the
installer created – project path, URL, Drupal/PHP versions, database
engine, name and user (or the SQLite file), PHP-FPM pool and socket,
Nginx files, log file – so the project can be removed or updated later.
**No password is ever stored there.** The file is read as plain data,
never executed.

```bash
./install.sh --list
```

shows all registered projects and marks those whose directory is gone.

## MariaDB and MySQL

Only one of the two can be installed natively: the Ubuntu packages use
the same port (3306), socket, `/etc/mysql` and `/var/lib/mysql`, so
installing one removes the other. When one is installed, the other is
listed as `[conflicts with installed …]` and cannot be chosen; the
installer explains why and offers two ways forward:

1. use the installed one – Drupal supports both with the same code;
2. for an exact match (for example with production), a container-based
   setup such as [DDEV](https://docs.ddev.com/en/stable/users/extend/database-types/)
   (Docker), e.g. `ddev config --database=mysql:8.4`.

PostgreSQL and SQLite can always be installed next to either of them.

## Databases that are too old

The minimum database versions come from the drupal.org requirements in
`config/compatibility.conf`. A database whose system version is older
(for example PostgreSQL 14 and SQLite 3.37 on Ubuntu 22.04 for Drupal 11)
is still listed, as `[too old: Drupal 11 needs 16+]`, and cannot be
chosen. The installer explains the options: a newer version from the
vendor's repository (it never adds package sources itself), another
database, DDEV (`ddev config --database=postgres:16`), or the previous
Drupal major when that one supports the installed version.

## The Drupal site

The site is installed with the **standard** profile. The site name is
the project name, the administrator is `admin` (`admin@example.com`).

Administrator password, chosen during the questions:

1. **Random** – 20 letters and digits, printed **once** at the end of the
   installation and saved nowhere. Put it in your password manager.
2. **Your own** – at least 8 characters, typed twice, never shown.

Lost it? `./drush user:login` prints a one-time login link (Drush knows
the project URL from the `./drush` launcher).

`web/sites/default/settings.php` is Drupal's own template plus a block
at the end with the database connection, `trusted_host_patterns` (only
`<project>.localhost` is accepted) and `config_sync_directory`
(`config/sync`, outside the web root).

No password ever appears in a command line (where other users could see
it with `ps`) or in the log: the database password goes into
`settings.php` through stdin, the administrator password is passed to
Drush through stdin. `site:install` itself prints a temporary password
in the log; it is replaced immediately and no longer works.

## Web server

Each project gets:

| File | Purpose |
| --- | --- |
| `/etc/php/<php>/fpm/pool.d/<project>.conf` | own PHP-FPM pool, runs as you (never root) |
| `/run/php/php<php>-fpm-<project>.sock` | the pool socket Nginx talks to |
| `/etc/nginx/sites-available/<project>.conf` | Nginx site for `http://<project>.localhost` |
| `/etc/nginx/sites-enabled/<project>.conf` | link that enables the site |
| `/var/log/nginx/<project>.error.log` | errors of this site only |

Before any reload the installer runs `php-fpmX.Y -t` and `nginx -t`. If a
check fails, the new file is removed and the running service is not
touched, so a mistake never takes down other projects. `*.localhost`
resolves to your own machine in browsers and curl, so no `/etc/hosts`
entry is needed.

Browsers try IPv6 (`::1`) first for `*.localhost`, so every site listens
on IPv4 and IPv6. After the reload the installer asks the site over both
and only shows the URL once Drupal really answers; otherwise everything
is rolled back. The check connects to `127.0.0.1` (and `[::1]` when that
address exists) and sends the site name as `Host`, exactly like a browser.
It does not depend on how `curl` resolves `*.localhost`, which older curl
versions (for example on WSL) cannot do. `./start` runs the same
check. This matters because a browser that once received another page
for the URL (for example the default Nginx page) may keep showing it
from its cache. If that ever happens, reload with **Ctrl+Shift+R**.

### Drush and Composer

Always use the project launchers, so the right PHP is used:

```bash
cd /var/www/<project>
./drush status
./composer require drupal/admin_toolbar
```

The projects directory can be changed with
`DRUPAL_PROJECTS_DIR=/srv/sites ./install.sh` (absolute path).

## Logs

Every installation writes a log file:

```
~/.local/state/drupal-local-installer/logs/<date>-<time>-<project>.log
```

- The full output of long commands (Composer, Drush) goes to the log;
  the screen shows one line per command with its result and duration.
- If a command fails, the screen shows its last lines and the log path.
- The log directory is readable only by you (`700`, files `600`).
- Passwords are never written to the log.
- `--verbose` shows everything on screen **and** writes it to the log.
- Logs are not deleted automatically; you can remove old ones at any time.

The location follows `XDG_STATE_HOME` if it is set.

## If something fails

- Failed steps are rolled back: everything the failed run created (Nginx
  site, PHP-FPM pool, database and database user, project directory) is
  removed again, newest first.
- If a rollback itself fails, the installer prints the exact command to
  finish the cleanup by hand.
- Check the log file shown at the end of the run.

## Removing a project

```bash
./install.sh --remove <project> --dry-run   # only shows what would be removed
./install.sh --remove <project>
```

Only projects in the registry are removed, and only what the registry
lists. Every path in the record is compared with the path the installer
itself would have created; anything unexpected stops the removal.

1. The plan is shown: Nginx site, PHP-FPM pool, database and database
   user (SQLite: the file inside the project), project folder, registry
   entry – each marked as existing or already gone – and a warning about
   uncommitted or unpushed git work. Packages, services, other projects
   and the logs are never touched.
2. A backup is offered (default yes).
3. You type the project name to confirm; then the sudo password is asked.
   The backup is made now: `mysqldump` / `pg_dump` (through sudo, so it
   also works for Drupal 7 and without Drush) and the project folder
   without `vendor/` (Composer recreates it), in
   `~/drupal-local-installer-backups/<project>-<date>/` (directory 700,
   files 600; they contain `settings.php`). If the backup fails, nothing
   is removed.
4. Removal runs newest first: Nginx site, PHP-FPM pool, database, folder.
   The registry entry is removed last and only if everything else
   succeeded, so a failed removal can simply be run again.

**Data that is not backed up cannot be recovered.**

Projects that are not in the registry (made by hand, or before the
registry existed) are never removed automatically: the installer lists
what it finds with that name and prints the commands to remove it by hand.
Register them first with `--scan`.

`./install.sh --unregister <project>` removes only the registry entry and
leaves everything else as it is.

## Existing projects (`--scan`)

```bash
./install.sh --scan
```

looks in `/var/www` for Drupal projects that are not registered and asks,
one by one, whether to register them. Detection only reads files:

- Drupal version and web root (`web/`, `docroot/`, `html/`, `public/` or
  the project root; Drupal 7 too),
- the enabled Nginx site whose `root` is that web root: URL and PHP-FPM
  socket (or TCP address). The PHP version comes from the socket name
  (`php8.3-fpm…`), or else from the pool that listens on it
  (`/etc/php/8.3/fpm/pool.d/…`, `/var/run` and `/run` count as the same),
- the PHP-FPM pool, but only if it serves this site alone – a shared pool
  such as `www.conf` is never recorded,
- the database (engine, name, user – never the password) through the
  project's own Drush, when it has one (run with the project's PHP, or
  with the system's default `php` when that version is unknown).

Such projects are registered as **adopted**. The installer never changes
their configuration. Their support level is recorded and shown in
`--list`: `supported`, `php_missing (…)`, or `unsupported (Drupal 7 is end
of life)` – a later Docker/DDEV mode is planned for those.

Removing an adopted project (`--remove`) works like for any other project,
with three extra rules: shared resources are never touched, the database
**user** is kept (it may be shared; only the database is dropped), and an
Nginx site that no longer serves the project is left in place.

## Development

```bash
bash tests/run.sh                                   # all test suites
shellcheck -S style -x install.sh lib/*.sh tests/*.sh
```

Tests never change the real system: they use mocks, stub commands and
temporary directories.

## Roadmap

- [x] Questions, compatibility matrix, PHP selection
- [x] Project directory, Composer and Drush with the project PHP
- [x] Readable output, logs, `--verbose`, `--step`
- [x] Database creation (MariaDB/MySQL, PostgreSQL, SQLite) in the workflow
- [x] Nginx site and PHP-FPM pool, validated before activation
- [x] `drush site:install`, administrator password, sudo asked once
- [x] Final checks and project registry (`--list`)
- [x] Remove a project (`--remove`, backup offer, typed confirmation, `--dry-run`)
- [x] Register existing projects (`--scan`, adopted, support levels)
- [ ] Update a project
- [ ] Optional package source for other PHP versions; Docker mode
