//! The `bosun` executable: everything lives in the library so other native
//! front ends can offer the same behaviour as a subcommand.

fn main() {
    bosun::run(std::env::args_os().skip(1))
}
