//! bosun — a process-attribute launcher: the few lines that must run INSIDE
//! the child, between fork and exec, which managed runtimes (.NET, BEAM, JVM)
//! cannot reach from their spawn APIs.
//!
//! ```text
//! bosun [--pdeathsig <SIG>] [--pdeathsig-soft <SIG>] [--parent <pid>]
//!       [--no-setsid] -- <command> [args...]
//! ```
//!
//! What it does, in order, then EXECS the command in place (same pid):
//!
//! 1. `setsid()`: the child becomes session and process-group leader, so
//!    pgid == pid and kill(-pid) reaches every descendant, including
//!    reparented grandchildren a tree-walk cannot see. On by default;
//!    `--no-setsid` opts out.
//! 2. `PR_SET_PDEATHSIG` (Linux only): the kernel delivers `<SIG>` to this
//!    process when the spawning THREAD of the parent dies, however it dies,
//!    SIGKILL and OOM included. `--pdeathsig` errors where unsupported
//!    (macOS): silent capability loss is exactly the failure mode this tool
//!    exists to end. `--pdeathsig-soft` is the documented best-effort form
//!    for callers that prefer to degrade.
//! 3. `--parent <pid>`: closes the fork-to-prctl race. If the parent already
//!    died before prctl took effect, the death signal will never fire, so we
//!    detect the reparent (getppid() != pid) and deliver the signal to
//!    ourselves immediately.
//!
//! Exit codes follow env(1)/nohup(1): 125 bosun itself failed (bad flags,
//! setsid/prctl failure), 126 command found but could not be executed, 127
//! command not found, otherwise the command's own status (exec replaces us).
//!
//! The library form exists so another native front end (pharos's shim) can
//! offer the same behaviour as a subcommand without shipping a second binary:
//! hand [`run`] the arguments that follow the subcommand.

use std::ffi::{CString, OsStr, OsString};
use std::io;
use std::os::unix::ffi::OsStrExt;

pub const USAGE: &str = "usage: bosun [--pdeathsig <SIG>] [--pdeathsig-soft <SIG>] [--parent <pid>]\n             [--no-setsid] -- <command> [args...]\n";

/// What the flags asked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Options {
    pub setsid: bool,
    pub death_signal: Option<i32>,
    /// `--pdeathsig` (true) refuses where unsupported; `--pdeathsig-soft` (false) degrades.
    pub death_required: bool,
    pub expected_parent: Option<libc::pid_t>,
    pub command: Vec<OsString>,
}

/// The outcome of parsing: run a command, or print the usage and exit 0.
#[derive(Debug, PartialEq, Eq)]
pub enum Parsed {
    Run(Options),
    Help,
}

/// "TERM" | "SIGTERM" | "15" -> SIGTERM. Case-insensitive. Numbers are accepted
/// in 1..=64; 0 is refused (signal 0 is a liveness probe, never a disposition).
/// Names resolve to THIS platform's numbers (SIGUSR1 is 10 on Linux, 30 on macOS).
pub fn parse_signal(name: &str) -> Option<i32> {
    let upper = name.to_ascii_uppercase();
    let stripped = upper.strip_prefix("SIG").unwrap_or(&upper);
    if !stripped.is_empty() && stripped.bytes().all(|b| b.is_ascii_digit()) {
        return match stripped.parse::<i32>() {
            Ok(n) if (1..=64).contains(&n) => Some(n),
            _ => None,
        };
    }
    match stripped {
        "HUP" => Some(libc::SIGHUP),
        "INT" => Some(libc::SIGINT),
        "QUIT" => Some(libc::SIGQUIT),
        "KILL" => Some(libc::SIGKILL),
        "USR1" => Some(libc::SIGUSR1),
        "USR2" => Some(libc::SIGUSR2),
        "TERM" => Some(libc::SIGTERM),
        _ => None,
    }
}

/// Parse the arguments AFTER the program name. Errors are the message bosun
/// prints (prefixed "bosun: ") before exiting 125.
pub fn parse_args<I>(args: I) -> Result<Parsed, String>
where
    I: IntoIterator<Item = OsString>,
{
    let mut it = args.into_iter();
    let mut opts = Options {
        setsid: true,
        death_signal: None,
        death_required: false,
        expected_parent: None,
        command: Vec::new(),
    };
    let mut saw_separator = false;

    while let Some(a) = it.next() {
        match a.as_bytes() {
            b"--" => {
                saw_separator = true;
                break;
            }
            b"--no-setsid" => opts.setsid = false,
            b"--pdeathsig" | b"--pdeathsig-soft" => {
                let flag = a.to_string_lossy().into_owned();
                let v = it
                    .next()
                    .ok_or_else(|| format!("{flag} needs a signal argument"))?;
                let s = v.to_string_lossy();
                opts.death_signal =
                    Some(parse_signal(&s).ok_or_else(|| format!("unknown signal '{s}'"))?);
                opts.death_required = flag == "--pdeathsig";
            }
            b"--parent" => {
                let v = it
                    .next()
                    .ok_or_else(|| "--parent needs a pid argument".to_string())?;
                let s = v.to_string_lossy();
                opts.expected_parent = Some(
                    s.parse::<libc::pid_t>()
                        .map_err(|_| format!("bad --parent pid '{s}'"))?,
                );
            }
            b"--help" | b"-h" => return Ok(Parsed::Help),
            _ => return Err(format!("unknown flag '{}'\n{USAGE}", a.to_string_lossy())),
        }
    }

    if !saw_separator {
        return Err(format!("missing '--' before the command\n{USAGE}"));
    }
    opts.command = it.collect();
    if opts.command.is_empty() {
        return Err(format!("no command after '--'\n{USAGE}"));
    }
    Ok(Parsed::Run(opts))
}

fn fail(msg: &str) -> ! {
    eprintln!("bosun: {msg}");
    std::process::exit(125)
}

/// Apply the process attributes to THIS process. On success the caller execs.
pub fn apply(opts: &Options) -> Result<(), String> {
    // 1. Own session + process group. A freshly spawned child never leads a
    // group, so this cannot fail in practice; treat failure as fatal rather
    // than degrading silently.
    if opts.setsid && unsafe { libc::setsid() } == -1 {
        return Err("setsid failed (already a session leader?)".into());
    }

    // 2. Die-with-parent, where the kernel offers it.
    if let Some(sig) = opts.death_signal {
        apply_death_signal(sig, opts.death_required, opts.expected_parent)?;
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn apply_death_signal(
    sig: i32,
    _required: bool,
    expected_parent: Option<libc::pid_t>,
) -> Result<(), String> {
    let rc = unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, sig as libc::c_ulong, 0, 0, 0) };
    if rc != 0 {
        return Err("prctl(PR_SET_PDEATHSIG) failed".into());
    }
    // 3. The fork-to-prctl race: if the intended parent is already gone we
    // were reparented, and the death signal will never fire. Deliver it to
    // ourselves now, as if it had.
    if let Some(pp) = expected_parent {
        if unsafe { libc::getppid() } != pp {
            unsafe { libc::raise(sig) };
            std::process::exit(125); // only reached for a non-fatal signal
        }
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn apply_death_signal(
    _sig: i32,
    required: bool,
    _expected_parent: Option<libc::pid_t>,
) -> Result<(), String> {
    if required {
        return Err(format!(
            "--pdeathsig is not supported on {} (no PR_SET_PDEATHSIG equivalent); \
             use --pdeathsig-soft to degrade explicitly",
            std::env::consts::OS
        ));
    }
    // The soft form on a platform without it: a documented no-op the caller chose.
    Ok(())
}

/// Exec `command` in place (PATH search, same pid). Returns only on failure,
/// with bosun's exit code for it: 127 not found, 126 anything else.
///
/// bosun changes nothing it was not asked to: execvp(3) directly, not
/// `std::process::Command`, which resets SIGPIPE to its default and clears the
/// signal mask on the way. The payload inherits the caller's dispositions and
/// mask exactly. The `bosun` binary also skips Rust's runtime start-up (which
/// would ignore SIGPIPE before `main`); a library caller whose own runtime
/// changed SIGPIPE restores what it wants before calling [`run`].
pub fn exec(command: &[OsString]) -> (i32, io::Error) {
    let cargs: Result<Vec<CString>, _> =
        command.iter().map(|a| CString::new(a.as_bytes())).collect();
    let cargs = match cargs {
        Ok(c) => c,
        Err(_) => {
            return (
                126,
                io::Error::new(io::ErrorKind::InvalidInput, "argument contains a NUL byte"),
            )
        }
    };
    let mut ptrs: Vec<*const libc::c_char> = cargs.iter().map(|c| c.as_ptr()).collect();
    ptrs.push(std::ptr::null());
    unsafe { libc::execvp(ptrs[0], ptrs.as_ptr()) };
    let err = io::Error::last_os_error();
    let code = if err.raw_os_error() == Some(libc::ENOENT) {
        127
    } else {
        126
    };
    (code, err)
}

/// The whole tool: parse, apply, exec. Never returns.
pub fn run<I>(args: I) -> !
where
    I: IntoIterator<Item = OsString>,
{
    let opts = match parse_args(args) {
        Ok(Parsed::Run(o)) => o,
        Ok(Parsed::Help) => {
            eprint!("{USAGE}");
            std::process::exit(0)
        }
        Err(msg) => fail(&msg),
    };
    if let Err(msg) = apply(&opts) {
        fail(&msg);
    }
    let (code, err) = exec(&opts.command);
    eprintln!(
        "bosun: exec '{}': {}",
        OsStr::new(&opts.command[0]).to_string_lossy(),
        err
    );
    std::process::exit(code)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: &[&str]) -> Vec<OsString> {
        v.iter().map(OsString::from).collect()
    }

    #[test]
    fn signal_names_prefixes_case_numbers() {
        assert_eq!(parse_signal("TERM"), Some(libc::SIGTERM));
        assert_eq!(parse_signal("SIGTERM"), Some(libc::SIGTERM));
        assert_eq!(parse_signal("term"), Some(libc::SIGTERM));
        assert_eq!(parse_signal("kill"), Some(libc::SIGKILL));
        assert_eq!(parse_signal("9"), Some(9));
        assert_eq!(parse_signal("SIGHUP"), Some(libc::SIGHUP));
        assert_eq!(parse_signal("USR1"), Some(libc::SIGUSR1));
    }

    #[test]
    fn signal_refusals() {
        for bad in ["0", "65", "BOGUS", "", "SIG", "-9", "9x"] {
            assert_eq!(parse_signal(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn parses_flags_and_command() {
        let p = parse_args(args(&[
            "--pdeathsig",
            "KILL",
            "--parent",
            "42",
            "--no-setsid",
            "--",
            "sleep",
            "5",
        ]))
        .unwrap();
        assert_eq!(
            p,
            Parsed::Run(Options {
                setsid: false,
                death_signal: Some(libc::SIGKILL),
                death_required: true,
                expected_parent: Some(42),
                command: args(&["sleep", "5"]),
            })
        );
        match parse_args(args(&["--pdeathsig-soft", "TERM", "--", "true"])).unwrap() {
            Parsed::Run(o) => assert!(!o.death_required && o.setsid),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn flags_after_separator_belong_to_the_command() {
        match parse_args(args(&["--", "sh", "-c", "--no-setsid"])).unwrap() {
            Parsed::Run(o) => {
                assert!(o.setsid);
                assert_eq!(o.command, args(&["sh", "-c", "--no-setsid"]));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn errors_and_help() {
        assert_eq!(parse_args(args(&["--help"])).unwrap(), Parsed::Help);
        assert_eq!(parse_args(args(&["-h", "--bogus"])).unwrap(), Parsed::Help);
        for (a, want) in [
            (vec!["--bogus", "--", "true"], "unknown flag '--bogus'"),
            (vec!["true"], "unknown flag 'true'"),
            (vec!["--no-setsid"], "missing '--'"),
            (vec!["--"], "no command after '--'"),
            (vec!["--pdeathsig"], "--pdeathsig needs a signal argument"),
            (
                vec!["--pdeathsig", "NOPE", "--", "true"],
                "unknown signal 'NOPE'",
            ),
            (vec!["--parent", "x", "--", "true"], "bad --parent pid 'x'"),
            (vec!["--parent"], "--parent needs a pid argument"),
        ] {
            let err = parse_args(args(&a)).unwrap_err();
            assert!(err.starts_with(want), "{a:?}: {err}");
        }
    }
}
