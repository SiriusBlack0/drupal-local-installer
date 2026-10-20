# Drupal Local Installer

Interactive Bash installer that creates local Drupal projects on Ubuntu
(native or WSL). It asks a few questions, checks the system, installs what
is missing (only after you approve), and creates the project with the
correct PHP version.

> **Status:** work in progress. The installer creates a working Drupal
> site at `http://<project>.localhost`: project files (Drupal + Drush),
> database, PHP-FPM pool, Nginx site and `drush site:install`, and it
> removes, registers, updates and upgrades projects (10 → 11) and changes
> their PHP version. A Docker mode comes next. See [Roadmap](#roadmap).

## Requirements

- Ubuntu (native, or WSL with or without systemd)
- A normal user with `sudo` rights. Do **not** run the installer as root.
- Internet access (APT packages, Composer/Packagist)
- `curl` (installed by the installer when missing): it checks that a site
  answers over HTTP after installing, updating or changing PHP

## Usage

```bash
./install.sh            # normal run
./install.sh --step     # pause before each installation step
./install.sh --verbose  # show the full output of every command
./install.sh --help
./install.sh --install-completion   # Tab completion, once (see below)
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
├── config/sync/                     configuration export (drush config:export)
├── .gitignore, .git/                when you chose a git repository
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
vendor's repository (the installer never adds database package sources), another
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
at the end with `trusted_host_patterns` (only `<project>.localhost` is
accepted), `config_sync_directory` (`config/sync`, outside the web root)
and an include of `settings.local.php`. It has no secrets, so it can be
committed.

`web/sites/default/settings.local.php` (mode 600) holds the secrets: the
database connection and the hash salt. Git ignores it. Because both are
set before `site:install`, Drupal's installer leaves `settings.php`
alone; the final checks confirm that `settings.php` has no secrets.

No password ever appears in a command line (where other users could see
it with `ps`) or in the log: the database password goes into
`settings.local.php` through stdin, the administrator password is passed
to Drush through stdin. `site:install` itself prints a temporary password
in the log; it is replaced immediately and no longer works.

### Git repository

One of the questions: *Create a git repository with an initial commit?*
(default yes; the summary shows the answer). With yes, git is installed
if it is missing, and after the final checks:

- `git init` on branch `main`;
- `.gitignore`: what Composer downloads (`vendor/`, `web/core/`, contrib
  modules, themes, profiles, `web/libraries/`, `recipes/`,
  `drush/Commands/contrib/`), uploaded files (`web/sites/*/files/`),
  `private/` (SQLite database) and `settings.local.php`. An existing
  `.gitignore` keeps its lines; only missing ones are added;
- `.git/info/exclude` (this computer only, never shared): `./start`,
  `./drush`, `./composer` and `.drupal-local-installer/`, which point to
  this computer's PHP and services;
- `git add -A`, then a check that nothing secret is staged:
  `settings.local.php` or database settings in `settings.php` stop the
  commit. If the database password appears in a staged file, the files
  are listed (never the password) and you decide whether to commit
  (default no). A password shorter than 8 characters is not searched
  for, since it would match ordinary text (`1` is in almost every file);
- the output of this step is also in the log;
- the initial commit, when git knows your name and email. Otherwise the
  files stay staged and the commands to set them and commit are shown.

What goes into git: `composer.json`, `composer.lock`, `settings.php`,
`config/`, your custom modules and themes, and the files Drupal's
scaffold writes (`web/index.php`, `web/.htaccess`, ...). Git is
optional: a failure in this step is only a warning, the site works.

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
- **Ctrl+C** during an installation, `--update` or `--php` is safe: the
  installer first undoes what the run changed, then stops (exit code 130).
- **Network problems:** when Composer fails because of the network (for
  example "curl error 7 ... Failed to connect"), it is tried up to 3 times
  (after 10 and 30 seconds) before anything is rolled back. Other errors
  are not retried. The security check and the version lookup of
  `--check-updates` are asked once more as well; when they still cannot
  run, the output says so (`not checked`) instead of guessing.
- **One run per project:** `--update`, `--php` and `--remove` lock the
  project; a second run on the same project at the same time stops with
  a message instead of interfering.
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

looks in `/var/www` for Drupal projects that are not registered, shows
what it found, and lets you choose which to register from a list:

```
    [ ] All
  > [x] crmmanager           Drupal 10.6.18  /var/www/crmManager
    [ ] eventmanager         Drupal 10.6.16  /var/www/eventManager
        Continue (1 selected)
        Exit, change nothing
```

Up/Down move, Space selects (on *All*: all or none; `a` does the same),
Enter on *Continue* registers the selected ones, *Exit* or `q` changes
nothing. Without a terminal (for example in a pipe) the same choice is
typed as numbers: `1 3`, `2-4`, `a` for all, Enter to leave.
Detection only reads files:

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

`--unregister NAME` forgets one project; `--unregister` without a name
shows the same kind of list with all registered projects, and after a
`y` removes the chosen entries from the registry. Only the entries go:
files, database and web server stay, and `--scan` registers the projects
again.

Removing an adopted project (`--remove`) works like for any other project,
with three extra rules: shared resources are never touched, the database
**user** is kept (it may be shared; only the database is dropped), and an
Nginx site that no longer serves the project is left in place.

## Updating Drupal core (`--check-updates`, `--update`)

```bash
./install.sh --check-updates            # all registered projects, read only
./install.sh --update mysite --dry-run  # checks and plan, nothing changes
./install.sh --update mysite
```

`--check-updates` shows, for each project, the newest **PATCH** of the
installed minor, the newest **MINOR** the installer knows, the newest
release of the next **MAJOR** it knows (that one is an `--upgrade`), and
**SECURITY**: whether the version installed now has a published Drupal
core security advisory (`composer audit`). `VULNERABLE - update now`
means a security release exists for it; the projects to update are
listed at the end under `[ACTION]`.

Only **patch** (11.3.10 → 11.3.12) and **minor** (11.3 → 11.4) releases
of Drupal core are installed, and contributed modules are not touched.
Major upgrades (10 → 11) have their own command: `--upgrade` (below). A
minor release is offered only when it is in `config/compatibility.conf`.

Before anything changes, the installer checks that:

- the project folder belongs to you (Composer never runs as root);
- the project's PHP is installed and supported by the target release,
  and the database server is new enough;
- it is a Composer project with `drupal/core-recommended` or
  `drupal/core` (Drupal 7 is refused);
- `composer.json` and `composer.lock` have no uncommitted changes (git);
- the site works now (Drush bootstraps it);
- Composer can resolve the update (`--dry-run`). If a constraint in
  `composer.json` blocks it, Composer's reason is shown and nothing
  changes. `composer.json` itself is never edited: the version is fixed
  with `composer update --with`.

**Security advisories.** Composer 2.9 and newer refuses package versions
that have published security advisories. Then a target can need, for
example, a `guzzlehttp/guzzle` version with known problems (an old patch
release of an unsupported minor). The installer explains this in plain
words and lists the packages and advisories. Usually the other target
(a newer minor) is the better choice. You may still install it: type
`accept`, and the advisories are accepted **for this update only**
(`composer update --no-security-blocking`); `composer.json` is not
changed, and the registry notes what was accepted (`accepted_advisories`).
`--dry-run` shows the plan as it would be with them accepted.

The choice between a patch and a minor update says what each one is: the
patch stays on the same minor line; Drupal gives security fixes only to
recent minors.

The update then asks for the project name and runs: backup → maintenance
mode → `composer update` → `drush updatedb` → `drush cache:rebuild` →
maintenance mode off → checks (version, Drush, HTTP answer, new errors in
the status report). The registry records the new version.

The backup goes to
`~/drupal-local-installer-backups/<name>-update-<date>/` (folder 700,
files 600): the database and `composer.json`/`composer.lock`. Keep it
until you are sure the update is fine.

Right before Composer runs, the current code (`vendor/`, the
`installer-paths` folders such as `web/core` and `web/modules/contrib`,
and the scaffold files such as `web/index.php`) is copied to
`.drupal-local-installer/update-snapshot/` in the project folder, so a
failed update can be undone **without the network**. The copy is removed
after the update (or the restore) succeeds. When the disk is too full
for it, the installer says so and restores with `composer install`
instead.

Drupal makes `web/sites/default` read-only after the installation, but
the core scaffold has to replace `default.settings.php` and
`default.services.yml` in it. The folder is therefore writable for its
owner during the update and gets its old mode back afterwards (also after
a restore).

If any step fails, the code and, after `updatedb`, the database are
restored automatically; restoring the database uses sudo again, so it may
ask for your password.

Restore by hand, if the automatic restore fails (`B` is the backup folder):

```bash
cp B/composer.json B/composer.lock /var/www/mysite/ && (cd /var/www/mysite && ./composer install)
gunzip -c B/database.sql.gz | sudo mysql                       # MariaDB/MySQL
sudo -u postgres dropdb mysite && sudo -u postgres createdb -O "$(cat B/database.owner)" mysite \
  && gunzip -c B/database.sql.gz | sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d mysite   # PostgreSQL
cp B/database.sqlite /var/www/mysite/private/database.sqlite     # SQLite
```

Errors in the Drupal log are compared too: only errors logged **during**
the update are reported, not older ones.

If the project is in git, the installer lists what changed (composer
files, and the files the core scaffold writes, such as `web/index.php` and
`web/.htaccess`) and prints the commit; commit once the site works: the
next `--update` or `--upgrade` refuses uncommitted Composer files, so two
changes never mix. If it keeps its configuration in git too, run
`drush config:export` and commit that.

## Upgrading to a new major (`--upgrade`)

```bash
./install.sh --upgrade mysite --dry-run   # all checks and the plan
./install.sh --upgrade mysite
```

One major at a time: Drupal 10 → 11 (Drupal 11 → 12 once a stable 12.0
release is in `config/compatibility.conf`; for 10 → 12 run it twice). The
target is the newest release of the newest Drupal 11 minor the installer
knows. Drupal 7 is not upgraded: that is a migration, not an upgrade.
The steps, their minimum versions and the modules that left core are in
`config/upgrades.conf`.

### Checks first (also in `--dry-run`, nothing changes)

| Check | Blocks when |
|---|---|
| Start release | older than the first release the new major accepts updates from (Drupal 10.3 for 11): `--update` to a newer minor first |
| PHP | the new major does not support the project's PHP: change it first with `--php`, as its own step, so a problem is easy to trace (the installer names a version both releases run on) |
| Database | the server is older than the new major needs |
| Modules removed from core | an enabled module or theme that the new major no longer has in core (for Drupal 11: Actions UI, Activity Tracker, Book, Forum, Statistics, Tour) and composer.json does not require its drupal.org project: `composer require drupal/book`, or uninstall it |
| Upgrade Status | never blocks; errors in **custom** code ask you before the upgrade |
| Composer trial | Composer finds no way to install the new core (see below) |

**Upgrade Status** ([drupal.org/project/upgrade_status](https://www.drupal.org/project/upgrade_status))
scans the enabled modules and themes, contrib and custom, for code the new
major no longer supports (deprecated PHP APIs, `.info.yml`, Twig,
libraries). It is a Drupal module, so the installer explains it and asks:

1. **for this scan only** – added with Composer (development dependency),
   enabled, scan, then uninstalled and removed: composer.json,
   composer.lock and the database are as before;
2. **keep it** – it stays installed (run `./drush upgrade_status:analyze --all`
   or *Reports > Upgrade status* any time; remove it with
   `./drush pm:uninstall upgrade_status && composer remove --dev drupal/upgrade_status`);
3. **skip** the scan.

If it is already enabled, it is used without asking.

The most common finding in custom code is an `.info.yml` that allows only
the current major (`core_version_requirement: ^10`): Drupal 11 refuses
such a module or theme. The installer prints the exact one-line fix
(`^10 || ^11`, which keeps the site working on Drupal 10 until the
upgrade); commit it, then run the upgrade. Twig deprecations such as
the `spaceless` filter are shown as warnings: they still work with Twig 3,
which Drupal 11 uses, and break only with Twig 4.

**Composer trial**: the new requirements (`drupal/core-recommended ^11.x`,
the other core packages, `drush/drush ^13`) are written into a **copy**
of composer.json and composer.lock (`composer.dli-upgrade.json`, next to
the real files, removed again), and `composer update --no-install
--no-scripts` runs on that copy: only the copy of the lock file is
written; `vendor/`, the real files and the project's scripts are not
touched. Contrib projects may be updated within the constraints of your
composer.json.

When the new release brings a **Composer plugin** that composer.json
neither allows nor refuses yet (`allow-plugins`; for example
`symfony/runtime`), Composer would stop in the middle of the install. The
trial finds such plugins first, and you decide before anything changes:
allow them, install them with the plugin part switched off, or stop. When a drupal.org project has no release for the new major
that your composer.json allows, the installer names it and you decide:

1. **stop** – nothing changes. Then allow a newer release in composer.json,
   remove the module if it is unused, or apply a patch from its issue queue;
2. **lenient** – the [mglaman/composer-drupal-lenient](https://github.com/mglaman/composer-drupal-lenient)
   plugin is added (after the backup) and lists that project, so Composer
   ignores its `drupal/core` requirement. Its code was not released for the
   new major and may break pages or the site: test it, and remove it from
   `extra.drupal-lenient.allowed-list` once a real release exists. The
   registry notes it (`lenient_packages`).

### The upgrade

Like `--update`: you type the project name; sudo is asked once, before
Composer; backup (database, composer.json and composer.lock, offline copy
of the code); maintenance mode; the new requirements are written into
composer.json; `composer update`; `drush updatedb`; caches; then the same
checks (Drupal reports the new version, Drush bootstraps, the site answers
over HTTP), the new errors of the status report and of the Drupal log.
The plan lists the contrib projects that get a new release (for example
`webform 6.2.9 -> 6.3.1`). Any failure – also
Ctrl+C – restores the code, composer.json, composer.lock and, after
`updatedb`, the database. The registry gets the new version and
`upgraded_from`.

Afterwards, check what only a person can: log in, open the pages your
modules provide, submit a form. Then commit what changed (the installer
lists it; a new `recipes/` folder is written by Composer like `vendor/`,
so it usually belongs in `.gitignore`) and, if you keep configuration in
git, `./drush config:export`.

Back to the old major later (for example a week after, when something
turns out broken): restore the backup by hand, with the commands of
[Updating Drupal core](#updating-drupal-core---check-updates---update)
(`B` is the `mysite-upgrade-…` backup folder); changes made to the site
since the upgrade are lost then.

## Other PHP versions (`--php-source`)

Ubuntu has one PHP version per release (22.04: 8.1, 24.04: 8.3,
26.04: 8.5). Other versions come from Ondřej Surý's repository,
<https://packages.sury.org/php/> (he maintains PHP in Debian). His
Launchpad PPA `ppa:ondrej/php` is being replaced by it, and Ubuntu 26.04
is only served there.

```bash
./install.sh --php-source
```

shows the PHP versions installed and available, and offers to add the
repository. Nothing changes without a `y`. Then the installer:

- checks that the repository has packages for your Ubuntu release;
- downloads its keyring package (`debsuryorg-archive-keyring`), checks
  its name and that it holds an OpenPGP key, and shows the fingerprint;
- installs **only the key**, as
  `/usr/share/keyrings/debsuryorg-php-drupal-local-installer.gpg`. The
  package itself is not installed: it also puts the key in
  `/etc/apt/trusted.gpg.d`, where apt would trust it for every package
  source, not only this one;
- writes `/etc/apt/sources.list.d/php-sury.sources` (deb822, `Signed-By`
  that key only) and runs `apt-get update`;
- disables the old PPA file, if there is one, by renaming it to
  `.disabled` (a PPA line inside another file is shown for manual
  editing);
- removes the new source and key again, and enables the PPA again, if
  apt cannot use it.

Run it again later and it also checks for an old PPA that is still
active next to the new repository (apt would see the same PHP packages
twice, perhaps built for another Ubuntu release) and offers to disable
it; `--php` refuses to install PHP packages while it is active.

If the repository ever changes its signing key, `apt-get update` reports
it; run `./install.sh --php-source` again to fetch the new key.

Note: the repository also has newer builds of PHP packages you already
have; `apt upgrade` takes them from there afterwards. `--php` offers the
same step when the PHP version you ask for is not available.

## Changing the PHP version (`--php`)

```bash
./install.sh --php mysite 8.4 --dry-run   # checks and plan, nothing changes
./install.sh --php mysite 8.4
```

First, nothing changes while the installer checks that the site works now
(Drush; a site that is broken *because of* its PHP, e.g. Drupal 10.5 on
PHP 8.5 or a PHP that is no longer installed, may be changed: that is the
fix) and that the Nginx site uses a `fastcgi_pass` line it can switch.
Packages of the new PHP are planned: FPM, CLI, the extensions Drupal
needs, and the extension packages the old PHP has (`php8.3-redis` →
`php8.4-redis`); one that does not exist for the new PHP is shown as a
warning.

### Compatibility checks (also in `--dry-run`)

These run with the **new** PHP and change nothing. When the new PHP is
not installed yet, they run right after its packages are installed, and
the change stops there if needed (the packages stay).

| Check | What it finds | Result |
|---|---|---|
| Compatibility table | Drupal release that does not support that PHP | stops |
| `composer check-platform-reqs` | Core, contrib and libraries whose `composer.json` refuses that PHP or needs a missing extension | stops |
| `php -l` on the custom code (`web/modules/custom`, `web/themes/custom`, `web/profiles/custom`) | Syntax the new PHP does not accept | stops |
| Trial run: Drush bootstraps the site with the new PHP (CLI) | Fatal errors while Drupal loads every enabled module | stops |
| PHPCompatibility scan of the custom code | Functions and syntax the new PHP removed or deprecated | you decide |

PHPCompatibility is installed once, after you agree, in
`~/.local/share/drupal-local-installer/tools/phpcompatibility` (outside
every project; no project's `composer.json` changes). Version 10, the
first with rules for PHP 8.x, is still a pre-release, so its findings are
advice: with errors you are asked whether to go on.

**What no check can promise.** The checks see the code that is loaded and
what packages declare. A custom module can still call something the new
PHP removed on a page that is only opened later, or contrib can declare
a loose `php` requirement. So after the change the installer checks Drush
and the front page with the new PHP, reports **new errors in the Drupal
log** (dblog), and lists what to try yourself: log in, open the pages your
modules provide, submit a form, `./drush cron`,
`./drush watchdog:show --severity=Error`. Going back is one command,
`./install.sh --php mysite <old version>`, because the old PHP stays
installed and code and database are never changed.

Then, after the project name is typed: packages (apt shows them and asks;
nothing is ever removed) → a new PHP-FPM pool next to the old one
(`php-fpm8.4 -t`, reload) → the `fastcgi_pass` line of the Nginx site
switched to the new socket (`nginx -t`, reload) → `./drush`, `./composer`
and `./start` rewritten for the new PHP → checks (Drush and the HTTP
answer with the new PHP) → the old pool removed → registry updated.
Copies of the old Nginx site and launchers go to
`~/drupal-local-installer-backups/<name>-php-<date>/`. If a step fails,
the site, the launchers and the pools are restored; the packages stay.
Code and database are never changed, nor the system's default `php`.

When PHP was not installed yet, Composer can only check the packages
after it is installed; Composer then clears sudo's cached password, so
sudo asks once more.

**Adopted projects** (`--scan`) are changed the same way, but only their
`fastcgi_pass` line changes; the new pool copies the `user`, `group` and
`php_value`/`php_admin_value`/`env` lines of the old pool, and the old
pool is never removed (other sites may use it). A pool the installer
created for it by an earlier `--php` is removed by the next one. The plan says so before
you confirm. Projects without launchers then run Drush with the new PHP
by hand, e.g. `php8.4 vendor/bin/drush status`.

Settings in the new version's `fpm/php.ini` that differ from the old one
(`memory_limit`, `upload_max_filesize`, ...) are listed at the end.

## Tab completion (`--install-completion`)

```bash
./install.sh --install-completion
```

installs Tab completion for your user only (no sudo), in
`~/.local/share/bash-completion/completions/install.sh`; it works in every
new terminal (in the current one: `source` the file it names). Then:

| You type | Tab offers |
|---|---|
| `./install.sh --` | every option (`--update`, `--php`, `--remove`, ...) |
| `./install.sh --update ` (also `--upgrade`, `--php`, `--remove`, `--unregister`) | the registered projects |
| `./install.sh --php mysite ` | the PHP versions that project's Drupal release supports |
| `./install.sh --update mysite ` | `--dry-run` |

Project names come from the registry each time, so new projects appear at
once. Another program called `install.sh` keeps the normal file name
completion. Without the `bash-completion` package the file is not loaded
automatically: install it (`sudo apt-get install bash-completion`) or add
the `source` line to `~/.bashrc`. To remove it, delete the file.

## Development

```bash
bash tests/run.sh                                   # all test suites
shellcheck -S style -x install.sh lib/*.sh lib/*/*.sh tests/*.sh completion/*.bash
```

Code layout: `install.sh` loads the modules in `lib/` in a fixed order
(checked by `tests/module_structure.sh`). The larger modules are folders,
loaded by the file of the same name:

| Loader | Folder |
|---|---|
| `lib/database.sh` | `lib/database/`: `common.sh`, `mysql.sh`, `postgresql.sh`, `sqlite.sh` |
| `lib/system.sh` | `lib/system/`: `checks.sh`, `services.sh`, `apt.sh` |
| `lib/ui.sh` | `lib/ui/` (phase 1 questions): `project.sh`, `drupal.sh`, `php.sh`, `database.sh`, `admin.sh`, `git.sh`, `confirm.sh` |
| `lib/update.sh` | `lib/update/`: `check.sh`, `backup.sh`, `snapshot.sh`, `advisories.sh`, `update.sh` |
| `lib/upgrade.sh` | `lib/upgrade/`: `checks.sh`, `upgrade_status.sh`, `composer.sh`, `upgrade.sh` |
| `lib/php_change.sh` | `lib/php_change/`: `pool.sh`, `launchers.sh`, `checks.sh`, `php_change.sh` |

`lib/composer.sh` runs Composer and Drush of a project (used by
`--update`, `--php`, `--remove`). Modules only define functions and
variables; nothing runs while they are loaded.

Tests never change the real system: they use mocks, stub commands and
temporary directories. They need [ShellCheck](https://www.shellcheck.net/)
(`sudo apt-get install shellcheck`); the installer itself does not.

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
- [x] Update Drupal core: patch and minor (`--check-updates`, `--update`)
- [x] Change the PHP version of a project (`--php`)
- [x] Optional package source for other PHP versions (`--php-source`)
- [x] Major upgrades with Upgrade Status and a Composer trial (`--upgrade`)
- [x] New projects git ready (`settings.local.php`, `.gitignore`, initial commit)
- [ ] Docker mode
