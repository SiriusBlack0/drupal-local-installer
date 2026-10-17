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
   simulation and a second confirmation first), project directory,
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
(with `curl`, like a browser) and only shows the URL once Drupal really
answers; otherwise everything is rolled back. `./start` runs the same
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

## Removing a test project (manual, for now)

Until the "remove project" feature exists, remove the web server files,
the directory and, for MariaDB/MySQL or PostgreSQL, the database and
its user:

```bash
sudo rm -f /etc/nginx/sites-enabled/<project>.conf /etc/nginx/sites-available/<project>.conf
sudo nginx -t && sudo systemctl reload nginx          # without systemd: sudo service nginx reload
sudo rm -f /etc/php/<php>/fpm/pool.d/<project>.conf
sudo php-fpm<php> -t && sudo systemctl reload php<php>-fpm
sudo rm -rf -- /var/www/<project>

# MariaDB / MySQL
sudo mysql -e "DROP DATABASE IF EXISTS \`<db_name>\`; DROP USER IF EXISTS '<db_user>'@'localhost';"

# PostgreSQL
sudo -u postgres psql -c 'DROP DATABASE IF EXISTS "<db_name>";' -c 'DROP ROLE IF EXISTS "<db_user>";'
```

SQLite needs nothing extra: the database file is inside the project
directory.

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
- [ ] Final checks and project registry
- [ ] Remove a project (with backup offer and confirmation)
- [ ] Update a project
- [ ] Optional package source for other PHP versions; Docker mode
