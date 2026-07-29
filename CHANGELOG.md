# Changelog

## 1.0.0 — 2026-07-29

Fresh repository. `pool` is now a **single Python file, stdlib only** (`bin/pool`), with no
build step, no package manager, and no harness/sidecar coupling.

### Rewritten from hexa to Python

The previous `pool` was a hexa-lang program (`bin/pool.hexa`) that shipped via `hx install`,
was later absorbed into `dancinlab/sidecar`, and finally broke on PATH when its shim was
left pointing at a retired CLI. This rewrite is a faithful port of all 12 verbs and all 8
`pool init` bootstrap payloads — the embedded bash is carried over byte-for-byte, so remote
behaviour is unchanged — with the toolchain dependency removed.

### Changed in the port

- **Remote commands are dispatched as argv**, not through a local shell, so local quoting
  can no longer alter what the remote shell receives.
- **`pool on` / `pool init` / `pool clean` inherit stdout and stderr**, replacing the old
  poll-and-print loop. Output is genuinely live, and remote stderr is no longer swallowed.
- **Scripts are piped to `bash -s` over stdin** instead of being staged as `~/.pool/.script.sh`
  and `~/.pool/.probe.sh`. Two fewer temp files, and concurrent runs cannot race on them.
- **Parallel fan-out uses a thread pool** with a batch deadline; stragglers still exit 124.
- **`pool health` verdicts read the probe output, not the subshell exit code.** A failing
  `hexa loop --status` (or a missing `~/core/hexa-lang`) makes the whole `cd … && …` chain
  exit non-zero even when `hexa --version` answered, which collapsed 🟡 into 🔴 and made the
  documented three-state verdict unreachable.
- **Malformed `pool.json` is reported and left alone** instead of being read as an empty
  roster. The empty-clobber guard, `.bak` rotation, and atomic `rename(2)` write are kept.
- **`install.sh` warns when another `pool` shadows the install on PATH** — the exact failure
  that retired the previous build.

### Unchanged

All verbs, flags, output formats, exit codes, `~/.pool/pool.json` schema, the `POOL_STATE`
override, the 1-hour foreground dispatch ceiling, the two-tier disk-cleanup, and the
`akida` fan-out exclusion. Existing rosters work as-is.
