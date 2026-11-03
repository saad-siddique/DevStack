# Cleanup tab and MySQL compaction — design

Date: 2026-11-02. Status: approved by the user (sweep threshold 48 hours). Marked **(my call)** = the designer's choice, not something the user decided.
Examples use placeholder names on purpose: this repo is public, so no real site or database names go in it.

## Intent and why

One Mac (a Mac mini) runs several agent workflows at once. Each workflow runs a WordPress PHPUnit suite that creates its own
throwaway databases, and nobody reliably drops them: not every agent cleans up, and when the user asked agents to clean up,
some sessions ended halfway. The machine reached 439 databases (413 of them test lanes). Disk ran low once.

Two facts shape the design:

1. The databases are small. 439 of them total about 1.1 GB. What hurts is the count: 20,053 tables.
2. MySQL's catalog file `mysql.ibd` is 6.85 GB, of which 5.78 GB is free space. MySQL reuses that space but never returns it,
   and there is no in-place shrink (verified, see Evidence). Only dump, re-initialise, restore reclaims it.

The user wants one place in the dashboard to see what is abandoned versus live, drop it safely, optionally have a nightly
sweep do it, and get the catalog space back. It must keep working when any agent session dies partway.

Success: the user opens a **Cleanup** tab, sees every database no site owns, grouped by run, each marked throwaway / unknown and
locked / idle, with last write and size; drops what is selected in one click; later switches on a nightly sweep once the list
has proven right; and can compact MySQL to reclaim the catalog space, safely, with a rollback.

## Goals

- `devstack cleanup`: list (`--json`), classify, drop, pin, sweep. All work lives in this command; the dashboard tab, the
  nightly agent and anything else that wants to call it use the same command. Idempotent and safe to re-run after an
  interruption (repo convention). The locked rule below applies to every caller: an agent that has just finished a suite
  cannot drop its lanes until they have been quiet for 30 minutes, so the tab and the nightly sweep are the cleanup paths.
  A short-idle override for agents is deliberately not in v1, because it would bend the recent-write guard (my call).
- Dashboard **Cleanup** tab (new item in the left rail) in "C" form: review and drop by hand from day one; a switch for the
  nightly sweep, **off in the code until switched on once per machine** (the user means to switch it on on every dev machine); pin ("keep") per run; a strip at the top: disk free, database count,
  count not owned by a site, MySQL catalog size and free part.
- `devstack mysql-compact`: reclaim `mysql.ibd` (see below). Offered in the tab after cleanup, with the expected gain
  (`free_gb` from `information_schema.FILES`) shown beside the button.

## Non-goals

- A menu-bar app tab (my call; dashboard and CLI only for now).
- Deleting anything devstack did not create. `~/Work` (35 GB), `~/.cache` (9 GB) and `~/Library` (18 GB) are the machine's
  big folders; they may appear as a read-only line, never as something the tab can delete (my call). Lowest priority.
- Changing how agents name databases or making agents call cleanup; the command just has to be easy for them to call.
- Automatic compaction; compaction for other MySQL versions.
- Docker anything (repo rule).

## Anti-goals (a failure even if it technically works)

- Dropping a database a site owns, or one with a live connection or a very recent write.
- Leaving a half-finished state after an interruption (a lost session, a closed browser tab, a killed process).
- A sweep that deletes something the user would not have chosen: unknown databases are never swept, pinned runs never swept.
- Any real site or database name, hostname or screenshot of real data committed to the repo.

## Classification (derived from a 100-name sample; the rules are my call)

- **Owned** (never touched): the `DB_NAME` in each linked site's `wp-config.php` (parse the file; do not start WP-CLI per
  site: slow), every `db` value in the sites inventory (`sites.local.tsv`, which wins over `sites.tsv`), including protected
  sites, and the system schemas (`mysql`, `sys`, `information_schema`, `performance_schema`). Imported sites have random
  database names, so name patterns must never decide ownership.
- **Throwaway**: not owned, and either the name ends in `_single_<n>` or `_multisite_<n>` (the PHPUnit lane suffix; 97 of 100
  sampled names), or its options table has a test prefix (`test_`, `wptests_`; on the dev machine this caught 4 schemas the
  suffix missed). Only 15 of 100 carried a PR number, so PR-based rules would miss most.
- **Unknown**: not owned, neither signal. Listed, never pre-selected, never swept.
- **Run**: databases grouped by the name with the lane suffix removed, shown as one row ("tag, N lanes").
- **Locked**: a live connection uses it (`performance_schema.processlist`, group by `DB`) or its newest table-file write is
  under 30 minutes old (the 30 is my call). Locked rows cannot be dropped from the tab or the CLI.
- **Last write** = the later of (a) the newest `*.ibd` modification time in the schema's folder under the MySQL data
  directory and (b) `information_schema.TABLES.UPDATE_TIME`. (b) is exact while MySQL is up but was NULL for 3,075 of
  3,103 tables after a restart, so it is never the only signal; (a) alone could lag a lazy flush. A scratch test showed
  both moving at the moment of a write on an idle server. **Created** = oldest table `CREATE_TIME`.
- **Pre-selection in the tab**: throwaway, idle, not pinned. The sweep has its own, stricter rule (below).
- **Pins**: kept in `$DATA_DIR/cleanup.json` (run tags), together with the sweep on/off switch and threshold. A pinned run
  is not pre-selected, not swept, and a drop of it is refused (CLI and tab share the guard) until it is unpinned (my call).
- **Dropping**: `DROP DATABASE`. Throwaway databases are dropped without a backup. Anything else the user explicitly
  selects (an unknown one) is dumped compressed to `~/Backups/DevStack/_dropped/<stamp>/` first (my call). The result reports
  bytes freed as the sum of the schema's `.ibd` sizes (never `mysql.ibd`).
- **Nightly sweep** (the user's rule: only the parallel-lane databases, and only those unused for 48 hours): a LaunchAgent
  like `logs-prune` (`com.devstack.cleanup`, installed by bootstrap, a time that does not collide with 03:30 upgrades and
  04:00 log rotation; my call), which exits immediately unless the switch is on. It drops a database only when **all** hold:
  not owned; the name ends in `_single_<n>` or `_multisite_<n>`; its options table has a test prefix (both signals, so a
  database from some other tool that merely looks like a lane is left alone; databases matching only the prefix, such as
  `..._lanecp_currentpair_0`, are shown in the tab but never swept); no live connection; last write older than 48 hours
  (the threshold is a setting, default 48 h); not pinned. Each drop is appended to a log
  (`~/Library/Logs/DevStack/cleanup-sweep.log`: time, name, bytes freed), and the tab lists what tonight's sweep will drop.
  The switch is off in the code and turned on once per machine (`devstack cleanup --enable-sweep`; the setting persists
  across `devstack update`), because the repo is public and other people's databases may look like lanes (my call).
  A second benefit: churn settles `mysql.ibd` at its peak number of tables, so fewer lane databases alive at once keeps the
  catalog from growing back after a compaction.

## MySQL compaction — `devstack mysql-compact`

Verified on a throwaway instance (see Evidence): dump all, stop, new data directory, `--initialize-insecure`, restore.

1. Refuse if anyone but the command itself is connected (the user must stop workflows first). Refuse without enough free
   disk for the dump plus the new data directory, both estimated from live content (the old directory is only renamed in
   step 3, so its size is not needed; the refusal prints the numbers). Compaction never drops anything: it dumps and
   restores every database as is. The tab shows how many throwaway databases would ride along and recommends dropping them
   first; the step-5 counts are taken over everything dumped (my call).
2. Write a compressed dump of everything (all schemas, routines, events, triggers, and the `mysql` schema so users and grants
   survive) to `~/Backups/DevStack/_mysql-compact/<stamp>/`.
3. Stop `mysql@8.4`; **move** the old data directory to `var/mysql.before-compact-<stamp>` (never delete it yet).
4. Initialise a new data directory with the options bootstrap uses (root without a password, drop-in from
   `mysql/zz-devstack.cnf`), start, restore, `FLUSH PRIVILEGES`.
5. Verify schema, table and user counts equal the pre-compaction counts. On any mismatch: stop, move the old directory back,
   report.
6. Space is only regained when the user confirms (`--finish`) and the old directory is deleted. Until then the tab says so.
- State lives in `$DATA_DIR/mysql-compact.json` (current step), so a run killed halfway can resume or `--rollback`. Order that
  matters in practice: drop the throwaway databases first, so they are neither dumped nor restored.
- It takes MySQL down for minutes; every site and any running suite fails meanwhile. From the dashboard it must run
  detached and be polled (no `nohup` in the repo; background with `cmd < /dev/null > log 2>&1 &` and `disown`).

## Fit with the repo (constraints)

- `bin/*` is bash 3.2 (`set -euo pipefail`, `--json` on every command, non-zero on failure, resolves its own paths through
  `lib.sh`); a new `bin/` script gets a verb in `bin/devstack`, a line in `completions/_devstack` and in the README command
  block; `LC_ALL=C` on `sed`/`tr`/`grep` that read dumps.
- Dashboard (`dashboard/`, PHP, WordPress coding standards, tabs, Yoda conditions): reads are `GET /?api=…`; writes are
  `POST /?api=…` and need the `X-Devstack: 1` header; commands run through `devstack_run`, which is synchronous, so only
  short operations may use it. Existing tabs: Overview, PHP, Services, Upgrades, Logs, Tools.
- Protected sites (`protected=yes`) are never removed or archived; they are owned anyway, which keeps them out of the list.
- Every script idempotent and safe to re-run; `doctor` should be able to report the unowned count and the sweep state
  (optional, small).
- Destructive code gets more care than the repo's usual KISS: design for every case, no best-effort paths.

## Evidence behind the design (all measured)

- The mini: 439 databases (413 test lanes sharing one project prefix), 1.1 GB of data in total.
- `mysql.ibd` on the mini: 6.85 GB total, 5.78 GB free; 20,053 tables; `innodb_index_stats` 272,839 rows.
- A throwaway MySQL 8.4 instance: a fresh `mysql.ibd` is 28 MB; creating and dropping 60 schemas × 43 tables three times left it at
  56 MB (no further growth: freed space is reused); `OPTIMIZE TABLE` on the stats tables is refused ("not allowed with this
  MySQL version"); `ALTER TABLESPACE mysql …` fails ("reserved tablespace name"); dump + re-initialise + restore returned it to
  28 MB with 0 errors, all schemas and rows intact, and site-style users logged in with their old passwords.
- A 100-name sample of the mini's databases: 97 end in a lane suffix, 15 carry a PR number, 74 were created on one day.
- On an idle server a table file's modification time moved at the moment of a write, and so did `UPDATE_TIME` (scratch
  database on the dev machine, dropped afterwards).
- MySQL's write load from the test suites (not the subject of this design): mostly undo and dictionary writes; the redo log
  capacity was raised to 2 GB in `mysql/zz-devstack.cnf` (17% fewer bytes written).

## Left to the builder

- JSON shapes, thresholds as settings, the tab's layout within the dashboard's existing look, verb flags, test strategy.
  Suggested: a scratch `mysqld` for tests (`--no-defaults`, high port, `--mysqlx=OFF`; macOS caps socket paths at 104
  characters, so put the socket under `$HOME`), the way the compaction was verified.
- Whether `stack-status` carries the new counts or the tab calls `devstack cleanup --json` itself.
- How the tab shows `mysql-compact` progress.
