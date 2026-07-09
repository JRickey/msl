#[cfg(target_os = "linux")]
fn main() {
    std::process::exit(msl_auth::linux::run_ssh_agent());
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("msl-ssh-agent requires linux");
    std::process::exit(255);
}
