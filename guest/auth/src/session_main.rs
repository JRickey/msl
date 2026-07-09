#[cfg(target_os = "linux")]
fn main() {
    std::process::exit(msl_auth::linux::run_session());
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("msl-session requires linux");
    std::process::exit(255);
}
