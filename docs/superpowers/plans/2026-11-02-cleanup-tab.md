# Cleanup tab and MySQL compaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `devstack cleanup` (list, drop, pin, nightly sweep of parallel-lane test databases), `devstack mysql-compact` (reclaim `mysql.ibd`), and a dashboard **Cleanup** tab over both.

**Architecture:** Two new bash commands in `bin/` hold all the logic and speak `--json`; the dashboard (PHP + JS) only shells out to them through its existing `?api=` router; a LaunchAgent runs the sweep nightly. Tests run the real scripts against a throwaway `mysqld` on a high port, so nothing touches the live MySQL.

**Tech Stack:** bash 3.2 (macOS), `jq`, `mysql`/`mysqldump`/`mysqld` 8.4 from Homebrew, `zstd`, PHP 8 (dashboard), vanilla JS, launchd.

**Spec:** `docs/superpowers/specs/2026-11-02-cleanup-tab-design.md` (read it first; this plan names the interfaces, the spec holds the reasons).

## Global Constraints

- bash 3.2 only (no `mapfile`, no `declare -A`); `set -euo pipefail` (comes with `source bin/lib.sh`); `--json` on every command; non-zero exit on failure; scripts find their own paths through `lib.sh`; idempotent and safe to re-run. `LC_ALL=C` on `sed`/`tr`/`grep` that read dumps.
- New `bin/` script = verb in `bin/devstack` + line in `completions/_devstack` + line in the README command block.
- Dashboard PHP: WordPress coding standards, tabs, **Yoda conditions**; writes are `POST /?api=…` with header `X-Devstack: 1`; no `nohup` anywhere (background with `cmd < /dev/null > log 2>&1 &`).
- **Lock** = live connection (`performance_schema.processlist`, column `DB`) or last write under **30 minutes**. **Last write** = later of newest `*.ibd` mtime in the schema folder and `information_schema.TABLES.UPDATE_TIME`. Every query reading `information_schema.TABLES` must run `SET SESSION information_schema_stats_expiry = 0;` first (default cache is 86400 s; measured: `UPDATE_TIME` stayed NULL after an INSERT without it).
- **Owned** (never touched): `DB_NAME` in each linked site's `wp-config.php` (`$VALET_HOME/Sites/*` symlinks; parse with `sed`, never WP-CLI), every `db` value (column 4) in `$SITES_TSV`, and `mysql`, `sys`, `information_schema`, `performance_schema`.
- **Throwaway** = not owned and (name ends `_single_<n>` or `_multisite_<n>`, or an options table whose name starts `test` or `wptests` and ends `options`). **Unknown** = unowned, neither. **Sweepable** = lane suffix **and** test-prefixed options table, unowned, unlocked, last write older than **48 hours** (`cleanup.json` setting, default 48), not pinned. Unknown is never pre-selected, never swept.
- Pinned run: not pre-selected, not swept, drop refused (CLI and tab) until unpinned.
- Dropping a non-throwaway database first dumps it to `~/Backups/DevStack/_dropped/<stamp>/<db>.sql.zst`; throwaway is dropped without a dump.
- Files: settings and pins `$DATA_DIR/cleanup.json`; sweep log `~/Library/Logs/DevStack/cleanup-sweep.log` (time, name, bytes); compaction state `$DATA_DIR/mysql-compact.json`; compaction dump `~/Backups/DevStack/_mysql-compact/<stamp>/`; old data folder `<datadir>.before-compact-<stamp>`; LaunchAgent label `com.devstack.cleanup`, 03:00 daily.
- The repo is public: tests and docs use placeholder names (`suite_pr1_final_single_0`), never real database, site or host names.
- Execute in this working tree (earlier uncommitted work in `bin/lib.sh`, `bin/doctor`, `bootstrap.sh` is a dependency). Commit steps below run only if the user has asked for commits; otherwise skip them and leave the tree uncommitted.

## Review Focus

Failure modes the spec implies but a straight reading would miss; each has a named test in the owning task.

1. A database name with a hyphen (real machines have them) breaks unquoted SQL or shell word splitting. Expected: listed and droppable. (Task 2 list, Task 3 drop)
2. A linked site whose folder is gone, or a folder with no WordPress `wp-config.php`. Expected: skipped for ownership, listing still succeeds. (Task 2)
3. A drop run killed halfway and run again. Expected: already-gone databases are reported, not errors; the rest proceed. (Task 3)
4. A database written to between the listing the user looked at and the click. Expected: refused as locked at drop time, because the guard re-scans. (Task 3)
5. Compaction interrupted after any step. Expected: re-running resumes at the next step; `--rollback` restores the old folder; a count mismatch rolls back by itself. (Task 6)

---

### Task 1: Test harness and MySQL socket override

**Files:**
- Create: `tests/run.sh`, `tests/lib/assert.sh`, `tests/lib/scratch-mysql.sh`, `tests/lib/scratch-mysqld`, `tests/smoke.test.sh`
- Modify: `bin/lib.sh` (the `mysql_new` helper near the bottom of the wp/mysql helpers)

**Interfaces:**
- Produces in `bin/lib.sh`: `mysql_new <mysql args…>` unchanged, but adds `-S "$MYSQL_SOCK"` when `MYSQL_SOCK` is set; `mysql_datadir` → prints `@@datadir` (trailing slash).
- Produces in `tests/lib/assert.sh`: `assert_eq <expected> <actual> <label>`, `assert_match <regex> <actual> <label>`, `assert_status <expected-exit> <label> <cmd…>`, `test_summary` (prints pass/fail counts, exits 1 on any failure). Expected value always first (Yoda).
- Produces in `tests/lib/scratch-mysql.sh`: `scratch_mysql_start` (initialises a data folder under `$SCRATCH_ROOT`, starts the server, exports `MYSQL_SOCK`, `MYSQL_DATADIR`, `SCRATCH_ROOT`, `MYSQLD_BIN`), `scratch_mysql_stop` (shutdown and delete), `scratch_sql <sql>` (client with `-N`). Socket is `$HOME/.devstack-test.sock` (macOS caps socket paths at 104 characters); port 33999; `--mysqlx=OFF`; always `trap`-stopped.
- Produces `tests/lib/scratch-mysqld`: executable wrapper that execs Homebrew's `mysqld` with `--no-defaults --basedir --socket="$MYSQL_SOCK" --mysqlx=OFF --port=33999 --bind-address=127.0.0.1 --innodb-flush-log-at-trx-commit=2 --skip-log-bin "$@"`; `MYSQLD_BIN` points at it.
- Produces `tests/run.sh`: runs every `tests/*.test.sh` in its own `bash`, prints one line each, exits non-zero if any failed.

- [ ] **Step 1: Write `tests/smoke.test.sh`**: sources both libs, `scratch_mysql_start`, creates schema `smoke_db`, then asserts `assert_eq "smoke_db" "$(source bin/lib.sh; mysql_new -N -e "SHOW DATABASES LIKE 'smoke_db'")" "mysql_new follows MYSQL_SOCK"` and `assert_match '/$' "$(mysql_datadir)" "datadir ends with a slash"`.
- [ ] **Step 2: Run `bash tests/run.sh`**. Expected: FAIL (`scratch_mysql_start: command not found`).
- [ ] **Step 3: Implement the libs, the wrapper, `tests/run.sh`, and the two `bin/lib.sh` changes** (`MYSQL_SOCK` branch inside `mysql_new`; new `mysql_datadir`).
- [ ] **Step 4: Run `bash tests/run.sh`**. Expected: `smoke  PASS`, exit 0, no stray `mysqld` (`pgrep -f port=33999` prints nothing) and no `~/.devstack-test.sock`.
- [ ] **Step 5: Commit** `tests: scratch-mysqld harness; mysql_new honours MYSQL_SOCK` (only if commits were asked for).

---

### Task 2: `devstack cleanup` — scan, classify, list

**Files:**
- Create: `bin/cleanup` (mode 755), `tests/cleanup-list.test.sh`
- Modify: `bin/devstack` (verb `cleanup` in the `case`, one usage line under "Sites"), `completions/_devstack` (command list entry and flags), `README.md` (command block line and a short "Cleanup" section)

**Interfaces:**
- Consumes: Task 1 (`mysql_new`, `mysql_datadir`, scratch harness). Env overrides honoured: `VALET_HOME`, `SITES_TSV`, `DATA_DIR`, `MYSQL_SOCK`.
- Produces: `devstack cleanup [--json]` (default action). With `--json` prints exactly this shape (human mode prints a table of the same rows):

```json
{"generated_at":"2026-11-02T20:00:00Z","disk_free_bytes":0,
 "mysql":{"databases":0,"owned":0,"unowned":0,"catalog_bytes":0,"catalog_free_bytes":0},
 "sweep":{"enabled":false,"older_than_hours":48,"next":["tag"]},
 "pinned":["tag"],
 "runs":[{"tag":"suite_pr1_final","kind":"throwaway","sweepable":true,"lanes":2,
          "databases":["suite_pr1_final_single_0","suite_pr1_final_single_1"],
          "files_bytes":0,"created":"ISO-8601","last_write":"ISO-8601","idle_seconds":0,
          "state":"idle","locked_reason":null,"pinned":false}]}
```

  `kind` is `throwaway` or `unknown`; `state` is `idle` or `locked`; `locked_reason` is `null`, `"connection"` or `"recent_write"`. Runs are sorted oldest `last_write` first. A lane database's `tag` is its name minus the lane suffix; any other database is its own run (`tag` = name, `lanes` 1). Run-level fields: `kind` throwaway only if every database is; `sweepable` only if every database is; `state` locked if any database is; `last_write` the latest. `catalog_*` come from `information_schema.FILES` where `FILE_NAME LIKE '%mysql.ibd'` (`TOTAL_EXTENTS`/`FREE_EXTENTS` × `EXTENT_SIZE`); `disk_free_bytes` from `df -k "$HOME"`. `pinned` and `sweep.enabled`/`older_than_hours` are read from `$DATA_DIR/cleanup.json` when it exists (defaults: no pins, `false`, 48); `sweep.next` is `[]` until Task 4 fills it. Owned databases are counted in `mysql.owned` and never appear in `runs`. MySQL not answering: print `{"error":"mysql not answering"}` and exit 1.
- Produces internal functions in `bin/cleanup` that Tasks 3 and 4 call: `owned_dbs` (names, one per line), `is_lane <db>` (exit 0 if lane suffix), `lane_tag <db>`, `scan_json` (prints the listing JSON above), `files_bytes <db>`.

- [ ] **Step 1: Write `tests/cleanup-list.test.sh`** with helpers `mk_db <name> <options-table>` (creates the schema and one table of that name), `age_db <name> <hours>` (`touch -t "$(date -v-<hours>H +%Y%m%d%H%M.%S)"` on every `.ibd` of the schema), `hold_connection <db> <seconds>` (background `mysql … -e "SELECT SLEEP(n)" <db>`), and a fake `VALET_HOME`/`SITES_TSV`/`DATA_DIR` under `$SCRATCH_ROOT`. Fixtures: `suite_pr1_final_single_0`, `suite_pr1_final_single_1` (options `test_options`); `other_tool_single_0` (options `wp_options`, lane suffix only); `suite_odd_lane_0` (options `test_options`, no suffix); `scratch_notes` (unknown); `hyphen-db_single_0` (options `test_options`); `site_one_db` owned by a fake linked site whose `wp-config.php` defines it; `inv_only_db` owned only through a `$SITES_TSV` row. All aged 2 hours so they are idle. Tests:
  - `list_classifies_every_fixture`: `suite_pr1_final` is one run, `lanes` 2, `kind` `throwaway`, `sweepable` `true`; `other_tool_single_0` `throwaway` with `sweepable` `false`; `suite_odd_lane_0` `throwaway`, `sweepable` `false`; `scratch_notes` `unknown`; `site_one_db` and `inv_only_db` absent from `runs` and counted in `mysql.owned`.
  - `list_handles_hyphenated_database_name` (Review Focus 1): `hyphen-db_single_0` appears under tag `hyphen-db`.
  - `list_marks_locked_by_connection`: with `hold_connection suite_pr1_final_single_0 5`, `state` is `locked`, `locked_reason` `connection`.
  - `list_marks_locked_by_recent_write`: age a lane database 2 hours (idle), then `INSERT` into its options table; `locked_reason` becomes `recent_write` (this exercises `UPDATE_TIME`; a never-aged fixture would be locked by its fresh file time and prove nothing).
  - `list_survives_dangling_site_and_non_wordpress_folder` (Review Focus 2): a `$VALET_HOME/Sites` symlink to a missing folder and one to a folder without `wp-config.php`; exit 0, fixtures unchanged.
  - `list_reports_error_when_mysql_down`: `MYSQL_SOCK=/nonexistent` → exit 1 and `{"error":…}`.
- [ ] **Step 2: Run `bash tests/run.sh`**. Expected: `cleanup-list FAIL` (`bin/cleanup: No such file`).
- [ ] **Step 3: Implement `bin/cleanup` with the functions above and the default list action.** Gather in a few queries, not one per database: one `information_schema.TABLES` query (with the stats-expiry `SET`) for `MAX(UPDATE_TIME)`, `MIN(CREATE_TIME)` per schema and the schemas that have a test-prefixed options table; one `performance_schema.processlist` query for connected `DB`s; one `find "$(mysql_datadir)<db>" -name '*.ibd'` pass per schema for mtime and bytes (`stat -f '%m %z'`, BSD flags). Assemble with `jq`. Argument parsing exits 2 with a usage line on unknown flags. Keep the Task 3/4 flag names (below) reserved in the usage text.
- [ ] **Step 4: Wire the verb, completion and README** (`cleanup)  exec "$BIN/cleanup" "$@" ;;`; completion flags `--json --drop --dry-run --yes --pin --unpin --sweep --enable-sweep --disable-sweep --older-than`).
- [ ] **Step 5: Run `bash tests/run.sh`**. Expected: all PASS. Then on the dev machine `time bin/cleanup --json | jq '.mysql'`: finishes in under 5 s with real counts; if slower, collapse the per-schema `find` into one pass.
- [ ] **Step 6: Commit** `cleanup: list and classify databases not owned by a site`.

---

### Task 3: `devstack cleanup` — pins and guarded drop

**Files:**
- Modify: `bin/cleanup`, `README.md`
- Create: `tests/cleanup-drop.test.sh`

**Interfaces:**
- Consumes: Task 2's `scan_json`, `owned_dbs`, `is_lane`, `lane_tag`, `files_bytes`.
- Produces: flags `--pin <tag>…`, `--unpin <tag>…` (edit `pinned` in `$DATA_DIR/cleanup.json`, create the file as `{"sweep":{"enabled":false,"older_than_hours":48},"pinned":[]}` when absent; idempotent), and `--drop <name-or-tag>… [--dry-run] --yes`. A target that names an existing database drops that database; otherwise it must equal a run tag and expands to its lanes. `--drop` without `--yes` exits 2 unless `--dry-run`. Result JSON: `{"dropped":[{"name":"…","bytes":0}],"refused":[{"name":"…","reason":"owned|locked|pinned|not_found_run|bad_name"}],"already_gone":["…"],"freed_bytes":0,"dry_run":false}`. Exit 0 when nothing was refused, 1 otherwise. Guard function `drop_guard <db>` prints the refusal reason or nothing, and **re-scans at drop time** (does not trust an earlier listing). Names must match `^[A-Za-z0-9_$-]{1,64}$` and are backtick-quoted in SQL. A database that is not throwaway is dumped first (`mysqldump --single-transaction --routines --events --triggers <db> | zstd -q -o "$BACKUP_ROOT/_dropped/<stamp>/<db>.sql.zst"`; `BACKUP_ROOT` defaults to `$HOME/Backups/DevStack`; reuse the variable if `bin/site-backup` already defines one) and the drop is refused if the dump fails.

- [ ] **Step 1: Write `tests/cleanup-drop.test.sh`** (same fixtures and helpers as Task 2, extracted into `tests/lib/cleanup-fixtures.sh` if both files need them). Tests:
  - `drop_throwaway_run_by_tag`: `--drop suite_pr1_final --yes` drops both lanes, `freed_bytes` > 0, schemas gone, no dump written.
  - `drop_refuses_owned_locked_pinned`: `site_one_db` → `owned`; a held connection → `locked`; after `--pin suite_pr1_final` → `pinned`; after `--unpin` the same drop succeeds.
  - `drop_unknown_dumps_first`: `--drop scratch_notes --yes` with `BACKUP_ROOT=$SCRATCH_ROOT/backups` leaves `_dropped/*/scratch_notes.sql.zst` and the schema is gone.
  - `drop_dry_run_changes_nothing`: `--dry-run` lists what would drop; schemas still exist.
  - `drop_handles_hyphenated_database` (Review Focus 1): `hyphen-db_single_0` drops cleanly.
  - `drop_twice_is_ok` (Review Focus 3): second identical command exits 0 with the names under `already_gone`.
  - `drop_refuses_database_written_after_listing` (Review Focus 4): list, then `INSERT` into the run's options table, then `--drop … --yes` → refused `locked`, schema still present.
  - `drop_rejects_bad_names`: `--drop 'a;b' --yes` → `bad_name`, exit 1, nothing executed.
  - `pin_is_idempotent`: pinning twice leaves one entry in `cleanup.json`.
- [ ] **Step 2: Run `bash tests/run.sh`**. Expected: `cleanup-drop FAIL`.
- [ ] **Step 3: Implement the pin flags, `drop_guard`, and `--drop`** as specified. Iterate databases one at a time so an interruption leaves a consistent state.
- [ ] **Step 4: Run `bash tests/run.sh`**. Expected: all PASS.
- [ ] **Step 5: README**: document `--drop`, `--pin`, the guard reasons and the pre-drop dump.
- [ ] **Step 6: Commit** `cleanup: pins and guarded drop`.

---

### Task 4: `devstack cleanup` — nightly sweep and settings

**Files:**
- Modify: `bin/cleanup`, `README.md`
- Create: `tests/cleanup-sweep.test.sh`

**Interfaces:**
- Consumes: Task 3's `drop_guard` and drop routine (the sweep calls the same code path, never a second implementation).
- Produces: `--enable-sweep`, `--disable-sweep`, `--older-than <hours>` (positive integer, else exit 2), all editing `$DATA_DIR/cleanup.json`; `--sweep [--dry-run]` which exits 0 printing nothing when the switch is off, and otherwise drops every sweepable run (listing JSON `sweepable` true, `state` idle, not pinned, `idle_seconds` > `older_than_hours` × 3600), appends one line per dropped database to `~/Library/Logs/DevStack/cleanup-sweep.log` (`<ISO time> <name> <bytes>`; `LOG_DIR` from `lib.sh`), and prints the Task 3 result JSON under `--json`. The listing's `sweep.next` is the list of run tags a sweep would drop now (computed with the same predicate function `sweepable_now <run-json>`, shared by `--sweep` and the listing).

- [ ] **Step 1: Write `tests/cleanup-sweep.test.sh`**. Tests (fixtures as before; set `LOG_DIR=$SCRATCH_ROOT/logs`):
  - `sweep_is_silent_and_inert_when_disabled`: aged lane run exists, no `--enable-sweep` → exit 0, empty output, run still there.
  - `sweep_drops_only_old_sweepable_lane_with_test_options`: enabled; `suite_pr1_final_*` aged 49 h → dropped and logged; a sibling run aged 47 h kept; `other_tool_single_0` aged 100 h kept (no test options); `suite_odd_lane_0` aged 100 h kept (no lane suffix); `scratch_notes` aged 100 h kept (unknown); a pinned aged run kept; an aged run with a held connection kept; owned databases kept.
  - `older_than_setting_changes_threshold`: `--older-than 1` makes the 47 h run sweepable.
  - `sweep_dry_run_lists_without_dropping`.
  - `listing_sweep_next_matches_what_sweep_drops`.
  - `older_than_rejects_non_numbers`: `--older-than abc` exits 2.
- [ ] **Step 2: Run `bash tests/run.sh`**. Expected: `cleanup-sweep FAIL`.
- [ ] **Step 3: Implement the settings flags, `sweepable_now`, `--sweep`, and the log append.**
- [ ] **Step 4: Run `bash tests/run.sh`**. Expected: all PASS.
- [ ] **Step 5: README**: sweep rule in one paragraph, `--enable-sweep` once per machine, where the log is.
- [ ] **Step 6: Commit** `cleanup: nightly sweep of idle parallel-lane databases`.

---

### Task 5: Nightly LaunchAgent and doctor

**Files:**
- Modify: `bootstrap.sh` (new `ensure_cleanup_agent`, called after `ensure_log_pruning`), `bin/uninstall` (agent list), `bin/doctor` (agent list and one new line), `README.md`
- Create: `tests/cleanup-agent.test.sh`

**Interfaces:**
- Consumes: Task 4 `--sweep`.
- Produces: `ensure_cleanup_agent` in `bootstrap.sh`: writes `~/Library/LaunchAgents/com.devstack.cleanup.plist` modelled on `ensure_log_pruning` (ProgramArguments `/bin/bash $REPO_DIR/bin/cleanup --sweep`, `StartCalendarInterval` Hour 3 Minute 0, `RunAtLoad` false, stdout and stderr to `$BREW_PREFIX/var/log/devstack-cleanup.log`, the same `PATH`/`HOME` environment), reloads only when the file changed. Agent lists in `bin/uninstall` and `bin/doctor` become `logs-prune upgrade watchdog cleanup`. New doctor check `cleanup` (always `ok`, informational): `sweep on|off, <n> parallel-lane databases idle over <hours> h` from `bin/cleanup --json` (`sweep.enabled`, count of runs with `sweepable` and `idle_seconds` over the threshold).

- [ ] **Step 1: Write `tests/cleanup-agent.test.sh`**: extracts the function with `sed -n '/^ensure_cleanup_agent() {/,/^}/p' bootstrap.sh`, runs it with `HOME` set to a scratch folder and `launchctl` shadowed by a shell function that records its arguments, then asserts the plist passes `plutil -lint`, contains `bin/cleanup` and `--sweep` and `<integer>3</integer>`, that a second run records no `bootout`/`bootstrap` call, and that `bash -n bin/doctor bin/uninstall` pass.
- [ ] **Step 2: Run `bash tests/run.sh`**. Expected: `cleanup-agent FAIL`.
- [ ] **Step 3: Implement `ensure_cleanup_agent`, the list changes and the doctor line.**
- [ ] **Step 4: Run `bash tests/run.sh`**, then `bin/doctor --json | jq '.checks[] | select(.name=="cleanup")'` on the dev machine. Expected: tests PASS; one `cleanup` check with status `ok`; `agent cleanup` shows `warn` ("LaunchAgent not loaded") until bootstrap runs, which is correct.
- [ ] **Step 5: README**: add the agent to the "LaunchAgents" description.
- [ ] **Step 6: Commit** `cleanup: nightly LaunchAgent and doctor line`.

---

### Task 6: `devstack mysql-compact`

**Files:**
- Create: `bin/mysql-compact` (mode 755), `tests/mysql-compact.test.sh`
- Modify: `bin/devstack` (verb `mysql-compact`, usage line), `completions/_devstack`, `README.md`

**Interfaces:**
- Consumes: Task 1 (`mysql_new`, `mysql_datadir`, scratch harness, `scratch-mysqld`).
- Produces: `devstack mysql-compact [--yes] [--json] [--stop-after <step>]`, `--status [--json]`, `--finish`, `--rollback`. Steps in order: `preflight dump stop move init start restore verify`. State file `$DATA_DIR/mysql-compact.json`: `{"stamp":"…","step":"<last completed or null>","pre":{"schemas":0,"tables":0,"users":0},"dump":"<path>","old_datadir":"<path>","done":false}`; running with a state file present resumes at the step after `step`. Env overrides (defaults in parentheses): `MYSQL_DATADIR` (`$BREW_PREFIX/var/mysql`), `MYSQL_STOP_CMD` and `MYSQL_START_CMD` (`$BREW_PREFIX/bin/brew services stop|start mysql@8.4`), `MYSQLD_BIN` (`$BREW_PREFIX/opt/mysql@8.4/bin/mysqld`), `MYSQL_SOCK`, `BACKUP_ROOT`. Behaviour per the spec: `preflight` refuses without `--yes`, if any connection other than its own exists, or if free disk is below `2 × (sum of data+index bytes) + 2 GB` (print the numbers; never use the old folder's size); records `pre` counts (schemas excluding system ones, tables, `mysql.user` rows); `dump` writes `all.sql.zst` (`mysqldump --all-databases --routines --events --triggers --single-transaction --set-gtid-purged=OFF | zstd`) and refuses to continue if it is empty; `move` renames the data folder to `<datadir>.before-compact-<stamp>`; `init` runs `"$MYSQLD_BIN" --initialize-insecure --datadir=<datadir>`; `restore` pipes the dump through `zstd -dc | mysql` then `FLUSH PRIVILEGES`; `verify` recomputes the three counts and, on mismatch, runs the rollback path automatically and exits 1. `--rollback` stops the server, deletes the new folder, moves the old one back, starts the server, clears the state file. `--finish` (only after `verify`) deletes the old folder and sets `done`. `--status --json` prints the state file or `{"step":null,"done":false}`. `--stop-after <step>` exits 0 after that step (for resume tests and for the dashboard's progress demo).

- [ ] **Step 1: Write `tests/mysql-compact.test.sh`**: scratch server with `MYSQLD_BIN`, `MYSQL_STOP_CMD`/`MYSQL_START_CMD` set to shell functions-as-scripts that stop and start the scratch server; fixtures: 3 schemas with rows, 2 users with passwords and grants, plus churn (create and drop 30 schemas × 20 tables) so `mysql.ibd` is larger than a fresh one. Tests:
  - `compact_reclaims_catalog_and_preserves_data`: after a full run plus `--finish`, `mysql.ibd` is smaller than before; schema, table and user counts equal the `pre` counts; row counts equal; each user logs in with its old password.
  - `compact_refuses_with_other_connections`: a held connection → exit 1, data folder untouched, no state file.
  - `compact_refuses_when_disk_too_low`: override the free-space probe through env `COMPACT_FREE_BYTES=1000` (documented test hook) → exit 1 and the message contains the required number.
  - `compact_requires_yes`: no `--yes` → exit 2.
  - `compact_resumes_after_interruption_at_every_step` (Review Focus 5): for each step `s` in `dump stop move init start restore`, run with `--stop-after $s`, assert `--status --json` reports `step` equal to `$s`, re-run without the flag and assert it completes and the data checks above hold; start from a fresh scratch server each time.
  - `compact_rolls_back_on_count_mismatch`: hook `COMPACT_TAMPER_PRE=1` (documented test hook) corrupts the recorded `pre.tables` before `verify` → exit 1, old folder back in place, the server answers, original data intact.
  - `rollback_after_interruption_restores_old_folder`: `--stop-after move`, then `--rollback`.
- [ ] **Step 2: Run `bash tests/run.sh`**. Expected: `mysql-compact FAIL`.
- [ ] **Step 3: Implement `bin/mysql-compact`** with one function per step, a `save_state` helper writing the JSON atomically (write temp, `mv`), and the three flags. `--json` prints the state after each run.
- [ ] **Step 4: Run `bash tests/run.sh`**. Expected: all PASS, no stray `mysqld`.
- [ ] **Step 5: Wire verb, completion, README** (a "Compact MySQL" paragraph: what it does, that MySQL is down for minutes, drop throwaways first, `--finish` is what returns the space).
- [ ] **Step 6: Do not run it against the live server.** Verify only with `bin/mysql-compact --status --json` (expected `{"step":null,"done":false}`) and `bin/mysql-compact` without `--yes` (expected exit 2).
- [ ] **Step 7: Commit** `mysql-compact: reclaim mysql.ibd by dump, re-initialise, restore`.

---

### Task 7: Dashboard backend

**Files:**
- Modify: `dashboard/index.php` (new API routes inside the `if ( '' !== $api )` block, before the 404; update the docblock list at the top), `README.md` (dashboard routes line if one exists)
- Create: `tests/dashboard-api.test.sh`

**Interfaces:**
- Consumes: Tasks 2–4 and 6 CLIs.
- Produces routes (all JSON):
  - `GET ?api=cleanup` → output of `bin/cleanup --json` (500 `{"error":…}` if the command fails).
  - `POST ?api=cleanup` with `op` in `drop`, `pin`, `unpin`, `sweep` and `names[]` (each must match `^[A-Za-z0-9_$-]{1,64}$`, else 400); `drop` also takes optional `dry_run=1`; `sweep` takes `value` = `on`, `off` or an integer hours (maps to `--enable-sweep`, `--disable-sweep`, `--older-than`). Returns the CLI JSON; HTTP 200 on exit 0, 409 with the CLI JSON when the CLI refused something (exit 1).
  - `GET ?api=mysql-compact` → `bin/mysql-compact --status --json`.
  - `POST ?api=mysql-compact` with `op` in `start` (spawns `bin/mysql-compact --yes --json` detached: `cmd < /dev/null > $home/Library/Logs/DevStack/mysql-compact.log 2>&1 &`, returns 202), `finish`, `rollback` (synchronous, short).
- Add a helper `devstack_spawn( array $argv, string $log, string $home ): void` next to `devstack_run`.

- [ ] **Step 1: Write `tests/dashboard-api.test.sh`**: starts `php -S 127.0.0.1:8099 -t dashboard` (with `HOME` set normally) and curls it. Tests: `get_cleanup_returns_listing_shape` (keys `runs`, `mysql`, `sweep`, `pinned`; read-only against the live MySQL), `post_without_header_is_403`, `post_drop_bad_name_is_400` (`names[]=a;b`), `post_drop_dry_run_changes_nothing` (`dry_run=1` for a name that does not exist → 200, `already_gone` contains it), `post_unknown_op_is_400`, `get_mysql_compact_reports_idle` (`step` null). Kills the server on exit.
- [ ] **Step 2: Run `bash tests/run.sh`**. Expected: `dashboard-api FAIL` (404 Unknown api).
- [ ] **Step 3: Implement the routes and `devstack_spawn`** in the file's existing style (Yoda, tabs, `devstack_json`).
- [ ] **Step 4: Run `php -l dashboard/index.php` and `bash tests/run.sh`**. Expected: no syntax errors, all PASS.
- [ ] **Step 5: Commit** `dashboard: cleanup and mysql-compact API`.

---

### Task 8: Dashboard Cleanup tab

**Files:**
- Modify: `dashboard/index.php` (nav button and `<section id="tab-cleanup">`), `dashboard/app.js` (add `'cleanup'` to `TABS`, `setTab` hook, `loadCleanup`, `renderCleanup`, event handlers), `dashboard/style.css`, `README.md` (Dashboard section: the tab)

**Interfaces:**
- Consumes: Task 7 routes through the existing `post( api, body )` helper and `fetch( '?api=cleanup' )`.
- Produces in `app.js`: `loadCleanup()` (called by `setTab('cleanup')` and every 60 s while the tab is visible, stopped on other tabs like the log timer), `renderCleanup( d )`, `pollCompact()` (every 3 s while a compaction is running). UI per the approved mockup "C": strip (disk free, databases, not tied to a site, MySQL catalog size and free part); sweep card (switch, hours field, "Run sweep now" is out of scope, "tonight's sweep will drop: …" from `sweep.next`); runs table (checkbox, run and lane count, Looks tag `throwaway`/`unknown`, created, last write, state, pin button) with checkboxes pre-ticked only for `kind` throwaway, `state` idle, not pinned; locked and pinned rows have disabled checkboxes; one **Drop N selected** button with an inline two-click confirm (no `window.confirm`); a **Compact MySQL** card showing `catalog_bytes`, `catalog_free_bytes`, how many throwaway databases would ride along ("drop them first"), a two-click confirm to start, a progress line from `?api=mysql-compact`, and Finish and Roll back buttons when the step is `verify`. Nav item goes after Logs, before Tools. Uses the dashboard's existing classes (`tab-head`, `act`, `quiet`, `count`, `alert`) and tokens in `style.css`; add only what is missing.

- [ ] **Step 1: Write the tab's HTML skeleton and `TABS` entry**; `node --check dashboard/app.js` after each JS edit.
- [ ] **Step 2: Implement `loadCleanup`/`renderCleanup`** (strip, runs table, selection, pin, drop, sweep card) and the styles.
- [ ] **Step 3: Implement the compaction card and `pollCompact`.**
- [ ] **Step 4: Verify in the browser** against the live dashboard (`https://dashboard.test/#cleanup`; Valet serves this repo's `dashboard/` folder directly): tab appears, strip numbers match `devstack cleanup --json`, locked rows have disabled boxes, dark mode legible, layout holds at phone width. Take a screenshot with the Chrome tools and look at it.
- [ ] **Step 5: Verify the drop flow end to end without touching real data**: create `devstack_ui_test_single_0` with a `test_options` table on the live local MySQL, age its `.ibd` 3 hours with `touch -t`, reload the tab, confirm only that run is pre-ticked among the idle throwaways you can see, drop it from the UI with the two-click confirm, confirm the schema is gone (`mysql -e "SHOW DATABASES LIKE 'devstack_ui_test%'"` prints nothing). Do not tick or drop any other row.
- [ ] **Step 6: README**: describe the tab and its confirmations; add a one-line pointer in the dashboard tab list.
- [ ] **Step 7: Commit** `dashboard: Cleanup tab`.

---

## Self-review

- **Spec coverage:** classification, locks, last-write signals, pins, drop guard and pre-drop dump (Tasks 2–3); 48 h sweep, log, enable-once switch (Task 4); LaunchAgent and doctor (Task 5); compaction with state, resume, rollback, disk check, throwaways ride along (Task 6); dashboard routes and the C-form tab with confirmations (Tasks 7–8); verbs, completions and README in each new-script task. Non-goals respected (no menu-bar app, nothing deleted outside devstack's footprint). Read-only outside-folder line from the spec's "lowest priority" note is deliberately left out of this plan and can follow.
- **Type consistency:** listing field names (`tag`, `kind`, `sweepable`, `state`, `locked_reason`, `idle_seconds`, `files_bytes`, `last_write`, `sweep.next`, `mysql.catalog_free_bytes`) are used identically in Tasks 2–4, 7 and 8; the drop result shape (`dropped`, `refused`, `already_gone`, `freed_bytes`, `dry_run`) is defined in Task 3 and consumed in Tasks 4 and 7; state-file step names are fixed in Task 6.
- **Review Focus** items 1–5 each map to a named test (Tasks 2, 3, 6).
