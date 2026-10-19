# bosun

**A process-attribute launcher: the ~30 lines that must run *inside* the child,
between `fork` and `exec`, which managed runtimes cannot reach.**

```
bosun [--pdeathsig <SIG>] [--pdeathsig-soft <SIG>] [--parent <pid>]
      [--no-setsid] -- <command> [args...]
```

`bosun` sets process attributes on itself, then **execs your command in place**
— same pid, so the handle your runtime got from `spawn` *is* the payload.

| attribute | what it buys | platforms |
|---|---|---|
| `setsid()` *(default)* | the child leads its own session + process group (`pgid == pid`), so `kill(-pid)` reaches **every descendant — including grandchildren that reparented to init**, which a process-tree walk structurally cannot | Linux, macOS |
| `--pdeathsig <SIG>` | the **kernel** delivers `<SIG>` to the child when its parent dies — *however* it dies: `SIGKILL`, OOM-killer, crash. No reaper process needed | Linux (`PR_SET_PDEATHSIG`) |
| `--parent <pid>` | closes the fork-to-prctl race: if the intended parent is already gone, the death signal would never fire — bosun detects the reparent and delivers the signal to itself immediately | Linux |
| `--no-setsid` | opt out of session leadership | — |

## Why this exists

Managed runtimes (.NET, BEAM, JVM, …) own their spawn path and expose no hook
into the window between `fork` and `exec` — the only place `setsid(2)` and
`prctl(PR_SET_PDEATHSIG)` can be called for a child. FFI does not help: those
calls affect the *calling* process. The classic workaround is prefixing spawns
with `setsid(1)` — but that utility is part of util-linux and **stock macOS
does not ship it**, so macOS spawns silently degrade to no-process-group,
leaking reparented grandchildren on every kill.

`bosun` is that wrapper, owned: `setsid` by syscall (works on macOS),
die-with-parent where the kernel offers it, loud refusal where it doesn't.

## Degradation is explicit, never silent

`--pdeathsig` on a platform without an equivalent (macOS) **fails with exit
125**. If you want best-effort, say so: `--pdeathsig-soft` applies the
attribute where supported and is a documented no-op elsewhere. Silent
capability loss is the exact failure mode this tool exists to end.

## Exit codes

Follows `env(1)`/`nohup(1)` conventions:

| code | meaning |
|---|---|
| 125 | bosun itself failed (bad flags, unsupported hard capability, setsid/prctl failure) |
| 126 | command found but not executable |
| 127 | command not found |
| else | the command's own exit status (`exec` replaces bosun) |

## Sharp edges, documented rather than hidden

- **pdeathsig fires when the parent's forking *thread* exits, not the parent
  process.** A parent that spawns from a pooled thread (.NET thread pool) can
  trigger it spuriously when that thread idles out. Spawn from a long-lived
  thread; use `--parent` to close the startup race (it cannot close the
  pooled-thread hazard).
- **Signal-0 liveness counts zombies.** After a group kill, the leader stays
  visible as a zombie until reaped; probe accordingly.
- `setsid()` fails if the caller is *already* a group leader. A freshly
  spawned child never is, so in the intended usage this cannot happen — bosun
  treats it as fatal (125) rather than degrading.

## Building

Rust (pinned in `rust-toolchain.toml`), `libc` as the only dependency. Linux
binaries are **musl-static** (run in `FROM scratch`); macOS binaries link
libSystem and are ad-hoc signed.

```sh
cargo test                       # unit tests (flag + signal parsing)
cargo build --release            # host binary -> target/release/bosun
./test/smoke.sh                  # behavioral contract against the real kernel
```

Every release target is built **natively on its own CI runner** and the smoke
suite runs against **the exact bytes that ship** (Linux also inside a bare
alpine container). v0.1.0 was Zig, cross-compiled from one Linux host while CI
smoke-tested separate native builds; its shipped binaries were never executed in
CI (captAInHook's Intel Mac payloads then crashed under the shipped
`x86_64-macos` one). v0.2.0 is the Rust port with
the same flags, exit codes and refusals, and it fixes one more cross-platform
bug: `USR1`/`USR2` now resolve to the platform's own numbers (they were the
Linux values everywhere).

The crate is also a library: `bosun::run(args)` is the whole tool, so another
native front end can offer it as a subcommand without shipping a second
binary.

## Distribution & pinning

Tagged releases publish per-target binaries + `SHA256SUMS` as GitHub release
assets. **Consumers must pin a tag and verify checksums** — never fetch
"latest". A silently updated binary changes your deploy bytes behind an
unchanged source tree, which breaks reproducible-deploy schemes (this is a
hard requirement for captAInHook's content-identity rendezvous).

```sh
V=v0.2.0; T=x86_64-linux
curl -fsSLO https://github.com/LoganBresnahan/bosun/releases/download/$V/bosun-$T
curl -fsSLO https://github.com/LoganBresnahan/bosun/releases/download/$V/SHA256SUMS
grep "bosun-$T\$" SHA256SUMS | sha256sum -c -
install -m 0755 bosun-$T /your/deploy/dir/bosun
```

## Consumers

- **[captAInHook](https://github.com/LoganBresnahan/captAInHook)** — replaces the
  `setsid(1)` PATH probe in its exec-handler spawn path; co-located in the
  deploy dir beside the engine and shim (native ⇒ no MVID ⇒ invisible to the
  content-identity hash by the same rule as the AOT shim).
- **pharos-mcp**: not for `setsid`. The BEAM's `erl_child_setup` already makes
  every port child a session leader, so bosun's default would fail with 125
  (pharos ADR-031). `--pdeathsig KILL --no-setsid` for language servers under
  the shared daemon is the open question there, linked as the library into
  pharos's Rust shim.

## Non-goals

- **Windows.** The equivalent containment primitive is a Job Object with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, which must be applied by the *parent*
  — a different shape that a child-side exec wrapper cannot provide. If a
  consumer needs Windows, that is a parent-side library, not this tool.
- **Supervision, restarts, timeouts.** Those belong to the caller. bosun sets
  attributes and gets out of the way — it is `exec`'d over within microseconds.

## License

MIT.
