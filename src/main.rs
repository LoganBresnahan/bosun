//! The `bosun` executable: everything lives in the library so other native
//! front ends can offer the same behaviour as a subcommand.
//!
//! `no_main`: Rust's runtime start-up sets SIGPIPE to ignored before `main`.
//! A launcher must hand the payload the caller's signal dispositions exactly,
//! so bosun takes the C entry point and never runs that start-up.
#![no_main]

use std::ffi::{CStr, OsString};
use std::os::raw::{c_char, c_int};
use std::os::unix::ffi::OsStringExt;

/// # Safety
/// Called by the C runtime with the process's argc/argv, as for any C `main`.
#[no_mangle]
pub unsafe extern "C" fn main(argc: c_int, argv: *const *const c_char) -> c_int {
    let args: Vec<OsString> = (1..argc as isize)
        .map(|i| {
            let p = unsafe { *argv.offset(i) };
            OsString::from_vec(unsafe { CStr::from_ptr(p) }.to_bytes().to_vec())
        })
        .collect();
    bosun::run(args)
}
