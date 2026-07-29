# pool

Minimal host roster + remote exec + one-shot bootstrap. **One Python file, stdlib only**,
state at `~/.pool/pool.json`. Nothing to install on the remote hosts — every payload is
plain bash sent over `ssh`.

```
$ pool list
                                  load  ram     gpu  disk        sudo  desc
summer  summer@10.0.0.60   linux  0.00  1/30G   0%   720G/915G   sudo
aiden   aiden@10.0.0.119   linux  1.00  21/30G  0%   666G/915G   sudo  shared CI runner
ghost   ghost@10.0.0.150   macos  2.98  4/24G   -    12Gi/926Gi        edge dataset host

$ pool on all 'uptime'
$ pool route 'make -j12 bench'      # → lands on the least-loaded host
```

## Install

```bash
git clone https://github.com/dancinlab/pool.git
cd pool && ./install.sh              # → ~/.local/bin/pool
```

Requires `python3` (3.8+) locally and key-based `ssh` to each host. `PREFIX=/usr/local
./install.sh` to install system-wide; `POOL_COPY=1` to copy instead of symlink. Or just
run `bin/pool` directly — it has no imports outside the standard library.

## Verbs

```bash
pool add <name> <user@host> [--sudo]   # register a host (ssh-probes `uname -s` for OS)
pool rm  <name>                        # remove from roster
pool list [--json] [--fast]            # roster + live cpu/ram/gpu/disk (--fast skips the probe)
pool on  <name> <cmd...>               # ssh + exec on host, streaming output
pool on  all <cmd...> [--jobs N] [--timeout S]   # parallel fan-out
pool route <cmd...>                    # dispatch to the lowest-load host
pool bg  <name> <cmd...>               # fire-and-forget dispatch (ssh -f -n)
pool status                            # live reachability probe
pool health                            # hexa-lang fleet probe; exit 1 on any failure
pool refresh                           # re-probe os for every host
pool init                              # bootstrap every host with all features
pool clean <name>|all [--dry-run] [--deep]   # run disk-cleanup now
pool desc <name> [text...]             # set a host description (shown in `pool list`)
```

Every remote payload is generic shell — pool carries no domain knowledge. Domain-specific
logic belongs downstream, as wrappers composing these verbs.

### `pool on` vs `pool bg`

`pool on` holds a foreground `ssh` and streams stdout live, bounded by a **1-hour wall-clock
ceiling** (exit 124). ssh keepalive only tears down a *dead* connection — a remote command
that wedges while the connection stays healthy is invisible to it, and one such job once
held a local ssh for ~3 hours. Anything genuinely long-running belongs on `pool bg`, which
uses `ssh -f -n` so the local client detaches right after auth; pair it with the canonical
`nohup ... > file 2>&1 &` on the remote side.

### `pool route`

Probes every routing-eligible host in parallel, ranks by 1-minute load average, and
dispatches to the lowest. Prints the ranking first, then streams:

```
→ summer  load 0.0
  aiden   load 1.0
  ghost   load 2.58
route → summer: echo hi
```

Dispatch is explicit and load-scored — never inferred from command content.

### `pool health`

Per-host [hexa-lang](https://github.com/dancinlab/hexa-lang) fleet probe: `hexa --version`
plus `hexa loop --status` from `~/core/hexa-lang`. `pool status` only proves ssh
reachability; fleet installs drift silently, so this is the one that catches it.

| verdict | meaning |
|---|---|
| 🟢 healthy | `hexa` answers and the loop verb dispatches |
| 🟡 loop-fail | `hexa` answers, loop verb fails or `~/core/hexa-lang` is missing |
| 🔴 broken | no usable `hexa` (or host unreachable) |

Exit 1 if any host is not 🟢 — so `pool health || alert` drives a cron / launchd watcher.

## `pool init` features

`pool init` runs every bootstrap feature on every host, in order. Adding a feature is one
tuple in `INIT_FEATURES`.

| feature | linux | macos |
|---|---|---|
| tailscale (headless) | `curl tailscale.com/install.sh \| sudo sh` | `brew install tailscale` + `brew services start tailscale` (CLI, not the GUI cask — avoids menubar conflicts) |
| `/etc/cron.daily/disk-cleanup` | the two-tier `pool clean` script, logged to `/var/log/pool-cleanup.log` | skipped (newsyslog + systemd-tmpfiles equivalents builtin) |
| no-sleep | skipped (Linux servers don't display-sleep) | `pmset -a displaysleep=0 sleep=0 disksleep=0` + screensaver `idleTime=0` — FileVault Macs sever sshd-reachable interfaces on display lock, breaking long headless builds |
| persistent-journal | `mkdir /var/log/journal` + restart journald (post-mortem logs survive reboot) | skipped (macOS unified log is persistent) |
| panic-recovery | `kernel.panic=10` + `kernel.panic_on_oom=0` — kernel auto-reboots 10s after panic instead of hanging | skipped (Darwin auto-restarts on panic) |
| earlyoom | `apt install earlyoom` + enable — userspace OOM-killer fires at <10% free RAM+swap, converting kernel hangs into clean per-process SIGKILL | skipped (macOS has Jetsam) |
| swapfile | 32 GB `/swapfile-pool` + fstab entry + `vm.swappiness=10` — only if existing swap < 30 GB | skipped (macOS manages swap dynamically) |
| watchdog | `softdog` + systemd `RuntimeWatchdogSec=30s` (auto-reset on kernel hang) | skipped (no equivalent userspace API) |

`tailscale up` still needs interactive auth — `pool init` only installs.

The OOM-resilience block (persistent-journal · panic-recovery · earlyoom · swapfile ·
watchdog) exists because of a real incident: a 17 GB checkpoint eval and a 17 GB upload
dispatched to the same 30 GB host in parallel saturated RAM, the kernel OOM-killer hung,
and the host needed a physical reboot. Each feature is one independent line of defense —
together they turn that into "earlyoom kills the lower-priority job; if it still escalates,
swap absorbs the spike; if the kernel still hangs, the watchdog resets within 30 s;
the persistent journal preserves the evidence; panic-recovery reboots in 10 s, not never."

## `pool clean`

Runs disk-cleanup immediately — no waiting for the daily cron — and reports freed space
(`df` before/after). Linux only; macOS hosts report skipped.

| tier | when | targets |
|---|---|---|
| safe | always | journalctl vacuum · `apt-get autoremove`/`clean` · snap disabled revisions · `/var/{log,crash,tmp}` · `/tmp` · `~/.cache/{uv,pip,puppeteer,mathlib,thumbnails}` |
| deep | `--deep`, or disk ≥ 85% | model caches `~/.cache/{huggingface,torch,torch_extensions,npm,yarn,go-build}` · `docker system prune` |

`--dry-run` counts what each tier would remove and deletes nothing. Uniform 3-day `mtime`
retention — `atime` is unreliable on `noatime` / `relatime` mounts. Tunable per run via
`POOL_CLEAN_THRESH` (default 85) and `POOL_CLEAN_RETAIN` (default 3).

## State

`~/.pool/pool.json` — override the path with `POOL_STATE=<path>`:

```json
{
  "hosts": [
    {"name": "summer", "ssh": "summer@10.0.0.60",  "sudo": true, "os": "linux"},
    {"name": "ghost",  "ssh": "ghost@10.0.0.150",  "os": "macos",
     "description": "edge dataset host — explicit dispatch only"}
  ]
}
```

| key | required | effect |
|---|---|---|
| `name` | yes | roster id, used by every verb |
| `ssh` | yes | ssh destination (`user@host` or a `~/.ssh/config` alias) |
| `os` | auto | `linux` · `macos` · `unknown`, probed on `add` / `refresh` |
| `sudo` | no | host may run the privileged `pool init` steps |
| `description` | no | free text · shown in `pool list` |

Concurrent agents share this one file, so writes are hardened three ways: an **empty-clobber
guard** (never replace a populated roster with an empty one unless it was an explicit `rm`),
**backup rotation** to `pool.json.bak`, and an **atomic** temp-file + `rename(2)` write so a
concurrent reader can never see a truncated file. A torn read recovers from the backup;
malformed JSON is reported and left untouched, never silently reset.

## Dispatch policy

- Hosts whose name or ssh target contains **`akida`** are hard-excluded from every implicit
  path — `on all`, `route`, `health`, `init`, `clean all`. Explicit `pool on pi5-akida <cmd>`
  still works. (Dedicated neuromorphic host; it is not a shared worker.)
- Dispatch is **explicit or load-scored**, never inferred from what the command looks like.
- macOS hosts stay workstations: keep them out of shared fan-out with a `description` and
  address them explicitly.

## License

MIT.
