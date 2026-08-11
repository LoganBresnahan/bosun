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

Zig 0.15+. Linux binaries are **musl-static** (28 KB; run in `FROM scratch`);
macOS binaries link libSystem. Every target cross-compiles from any host:

```sh
zig build test              # unit tests
zig build --release         # host binary -> zig-out/bin/bosun
./test/smoke.sh             # behavioral contract against the real kernel
zig build release --release # all targets -> zig-out/release/bosun-<arch>-<os>
```

## Distribution & pinning

Tagged releases publish per-target binaries + `SHA256SUMS` as GitHub release
assets. **Consumers must pin a tag and verify checksums** — never fetch
"latest". A silently updated binary changes your deploy bytes behind an
unchanged source tree, which breaks reproducible-deploy schemes (this is a
hard requirement for captAInHook's content-identity rendezvous).

```sh
V=v0.1.0; T=x86_64-linux
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
- **pharos-mcp** *(prospective)* — LSP children spawned under
  `bosun --pdeathsig KILL --parent <pid>` are kernel-reaped when pharos dies,
  eliminating orphaned language servers on Linux with no cleanup pass (the
  `PR_SET_PDEATHSIG` item its ADR-030 deferred). No NIF involved — bosun is an
  executable, spawned like any port program.

## Non-goals

- **Windows.** The equivalent containment primitive is a Job Object with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, which must be applied by the *parent*
  — a different shape that a child-side exec wrapper cannot provide. If a
  consumer needs Windows, that is a parent-side library, not this tool.
- **Supervision, restarts, timeouts.** Those belong to the caller. bosun sets
  attributes and gets out of the way — it is `exec`'d over within microseconds.

## License

MIT.
