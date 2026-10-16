# MariaDB/MySQL Replication Check

A cron-friendly replica health check for MariaDB and MySQL. It verifies the
replica I/O and SQL threads are running, that replication lag
(`Seconds_Behind_Master`) is under your thresholds, that no
`Last_IO_Error` / `Last_SQL_Error` is stuck, and that GTID sets have not
diverged — then reports Nagios-style exit codes and optionally emails you.

## Usage

```bash
# credentials live in ~/.my.cnf — the MySQL user needs REPLICATION CLIENT
./check-replication.sh --lag-warning 60 --lag-critical 300 \
    --to dba@example.com --from "replcheck@db2.example.com" --json
```

Example crontab (every 5 minutes):

```
*/5 * * * * /opt/bin/check-replication.sh --lag-warning 60 --lag-critical 300 \
    --to dba@example.com >> /var/log/replcheck.log 2>&1
```

## Options

| Option | Default | What it does |
|---|---|---|
| `--lag-warning SEC` | 60 | Warning when lag ≥ SEC |
| `--lag-critical SEC` | 300 | Critical when lag ≥ SEC |
| `--to EMAIL` | — | Mail a digest on warning/critical (needs `/usr/bin/mail`) |
| `--from EMAIL` | `replcheck@<hostname>` | Sender address for the digest |
| `--defaults-file PATH` | `~/.my.cnf` | Credentials file for the `mysql` client |
| `--json` | off | Machine-readable output |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK — replication healthy |
| 1 | Warning — high lag, NULL lag with running threads, or unexecuted GTIDs |
| 2 | Critical — thread stopped, stuck error, or lag over the critical threshold |
| 3 | Unknown — cannot connect, or the server is not a replica |

## Notes

- Works with both spellings: tries `SHOW REPLICA STATUS` first (MariaDB 10.5+ /
  MySQL 8.0.22+), then falls back to `SHOW SLAVE STATUS`.
- The GTID pending-transaction count understands both MySQL 8
  (`uuid:1-100`) and MariaDB (`0-1-1-100`) set formats.
- Put credentials in `~/.my.cnf` (`[client]` section, mode `600`) — the
  password never appears on the command line or in the process list.

MIT licensed.
