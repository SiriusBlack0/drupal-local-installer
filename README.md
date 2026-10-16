# Drupal Local Installer

Interactive Bash installer that creates local Drupal projects on Ubuntu
(native or WSL). It asks a few questions, checks the system, installs what
is missing (only after you approve), and creates the project with the
correct PHP version.

> **Status:** work in progress. The installer currently creates the project
> files (Drupal + Drush) and the database. Nginx/PHP-FPM setup and
> `drush site:install` are being added. See [Roadmap](#roadmap).

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

1. **Questions** – project name, Drupal version, PHP version, database.
   Nothing is changed on the system.
2. **Checks** – existing project, directory, Nginx config, packages,
   PHP extensions, services. Nothing is changed on the system.
3. **Installation** – only after you confirm: missing packages (with a
   simulation and a second confirmation first), project directory,
   Drupal, Drush, database.

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
├── drush                            runs Drush with the project PHP
├── composer                         runs Composer with the project PHP
├── private/database.sqlite          SQLite only, outside the web root
└── .drupal-local-installer/bin/php  link to the project PHP version
```

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

- Failed steps are rolled back: a project directory, database or database
  user created by the failed run is removed again.
- If a rollback itself fails, the installer prints the exact command to
  finish the cleanup by hand.
- Check the log file shown at the end of the run.

## Removing a test project (manual, for now)

Until the "remove project" feature exists, remove the directory and,
for MariaDB/MySQL or PostgreSQL, the database and its user:

```bash
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
- [ ] Nginx site and PHP-FPM pool, validated before activation
- [ ] `drush site:install`
- [ ] Final checks and project registry
- [ ] Remove a project (with backup offer and confirmation)
- [ ] Update a project
- [ ] Optional package source for other PHP versions; Docker mode
