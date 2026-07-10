#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("msl-way runs inside the Linux guest only");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
fn main() {
    std::process::exit(linux::run());
}

#[cfg(target_os = "linux")]
mod linux {
    use std::collections::HashMap;
    use std::io;
    use std::sync::Arc;
    use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError};
    use std::thread;
    use std::time::{Duration, Instant};

    use std::path::Path;

    use smithay::input::keyboard::XkbConfig;
    use smithay::input::{Seat, SeatState};
    use smithay::output::{Mode as OutputMode, Output, PhysicalProperties, Scale, Subpixel};
    use smithay::reexports::calloop::EventLoop;
    use smithay::reexports::calloop::ping::{Ping, make_ping};
    use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel::State as XdgState;
    use smithay::reexports::wayland_server::{Display, DisplayHandle};
    use smithay::utils::Transform;
    use smithay::wayland::compositor::CompositorState;
    use smithay::wayland::fractional_scale::FractionalScaleManagerState;
    use smithay::wayland::selection::data_device::DataDeviceState;
    use smithay::wayland::shell::xdg::XdgShellState;
    use smithay::wayland::shm::ShmState;
    use smithay::wayland::viewporter::ViewporterState;
    use vsock::VsockStream;

    use msl_way::comp::{self, ClientState, State};
    use msl_way::ledger::Ledger;
    use msl_way::remote::{
        Configure, Hello, HostMsg, Key, PROTOCOL_VERSION, Pointer, T_HELLO, T_HELLO_ACK, T_STATS,
        accept_host, bind_vsock, decode_hello_ack, read_frame, write_json,
    };
    use msl_way::{frames, input};

    const DEFAULT_VSOCK_PORT: u32 = 5020;
    const DISCONNECTED_ACCEPT_INTERVAL: Duration = Duration::from_millis(100);
    const HOST_QUEUE_CAP: usize = 1024;
    const DRAIN_BUDGET: usize = 256;

    struct Args {
        wayland_socket: Option<String>,
        vsock_port: u32,
        layout: String,
    }

    fn parse_args() -> Args {
        let mut a = Args {
            wayland_socket: None,
            vsock_port: DEFAULT_VSOCK_PORT,
            layout: "us".to_string(),
        };
        let mut it = std::env::args().skip(1);
        while let Some(flag) = it.next() {
            match flag.as_str() {
                "--wayland-socket" => a.wayland_socket = it.next(),
                "--vsock-port" => {
                    if let Some(v) = it.next().and_then(|s| s.parse().ok()) {
                        a.vsock_port = v;
                    }
                }
                "--layout" => {
                    if let Some(v) = it.next() {
                        a.layout = v;
                    }
                }
                _ => {}
            }
        }
        debug_assert!(a.vsock_port != 0, "vsock port 0 is reserved");
        debug_assert!(!a.layout.is_empty(), "keyboard layout must be non-empty");
        a
    }

    struct HostConn {
        write: VsockStream,
        rx: Receiver<HostMsg>,
    }

    /// The XKB dataset must exist before `add_keyboard`, which otherwise aborts
    /// inside libxkbcommon rather than returning an error.
    fn ensure_xkb_dataset() -> io::Result<()> {
        let root =
            std::env::var("XKB_CONFIG_ROOT").unwrap_or_else(|_| "/usr/share/X11/xkb".to_string());
        if Path::new(&root).is_dir() {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("XKB data not found at {root}; install xkb-data or set XKB_CONFIG_ROOT"),
            ))
        }
    }

    type Globals = (
        Output,
        DataDeviceState,
        ViewporterState,
        FractionalScaleManagerState,
    );

    fn install_globals(dh: &DisplayHandle) -> Globals {
        let output = Output::new(
            "MSL-1".to_string(),
            PhysicalProperties {
                size: (0, 0).into(),
                subpixel: Subpixel::Unknown,
                make: "msl".to_string(),
                model: "virtual".to_string(),
            },
        );
        let _global = output.create_global::<State>(dh);
        let mode = OutputMode {
            size: (comp::OUTPUT_W, comp::OUTPUT_H).into(),
            refresh: i32::try_from(comp::DEFAULT_REFRESH_HZ * 1000).unwrap_or(60_000),
        };
        output.change_current_state(
            Some(mode),
            Some(Transform::Normal),
            Some(Scale::Integer(1)),
            Some((0, 0).into()),
        );
        output.set_preferred(mode);
        (
            output,
            DataDeviceState::new::<State>(dh),
            ViewporterState::new::<State>(dh),
            FractionalScaleManagerState::new::<State>(dh),
        )
    }

    fn build_state(display: &Display<State>, layout: &str) -> io::Result<State> {
        debug_assert!(!layout.is_empty(), "keyboard layout must be non-empty");
        ensure_xkb_dataset()?;
        let dh = display.handle();
        let compositor = CompositorState::new::<State>(&dh);
        let shm = ShmState::new::<State>(&dh, Vec::new());
        let xdg = XdgShellState::new::<State>(&dh);
        let (output, data_device, viewporter, fractional) = install_globals(&dh);
        let mut seats = SeatState::<State>::new();
        let mut seat: Seat<State> = seats.new_wl_seat(&dh, "seat0");
        let xkb = XkbConfig {
            layout,
            ..XkbConfig::default()
        };
        let keyboard = seat.add_keyboard(xkb, 200, 25).map_err(|e| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("xkb keymap load failed ({e}); install xkb-data / set XKB_CONFIG_ROOT"),
            )
        })?;
        let pointer = seat.add_pointer();
        Ok(State {
            dh,
            compositor,
            shm,
            xdg,
            seats,
            seat,
            keyboard,
            pointer,
            output,
            data_device,
            viewporter,
            fractional,
            windows: HashMap::new(),
            surface_win: HashMap::new(),
            x11_windows: HashMap::new(),
            focus: None,
            next_win: 1,
            seq: 0,
            scale: 1.0,
            refresh_hz: comp::DEFAULT_REFRESH_HZ,
            epoch: Instant::now(),
            ledger: Ledger::new(),
            out: Vec::new(),
            dropped_input: 0,
            grabs: msl_way::popups::GrabStack::new(),
            dismissed: msl_way::popups::DismissedSet::new(),
            warned_popup_configure: false,
            xwayland_shell: smithay::wayland::xwayland_shell::XWaylandShellState::new::<State>(
                &display.handle(),
            ),
            xwm: None,
            shutdown: false,
        })
    }

    fn handshake(mut stream: VsockStream, state: &mut State, ping: Ping) -> io::Result<HostConn> {
        let distro = std::env::var("MSL_DISTRO").unwrap_or_else(|_| "linux".to_string());
        let hello = Hello {
            version: PROTOCOL_VERSION,
            distro,
        };
        write_json(&mut stream, T_HELLO, &hello)?;
        let frame = read_frame(&mut stream)?;
        if frame.msg_type != T_HELLO_ACK {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "expected hello_ack",
            ));
        }
        let ack = decode_hello_ack(&frame.payload)?;
        if ack.version != PROTOCOL_VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "protocol version mismatch",
            ));
        }
        state.scale = if ack.scale > 0.0 { ack.scale } else { 1.0 };
        state.refresh_hz = ack.refresh_hz_rounded();
        state.sync_output();
        let reader = stream.try_clone()?;
        let (tx, rx) = mpsc::sync_channel(HOST_QUEUE_CAP);
        thread::spawn(move || reader_loop(reader, &tx, &ping));
        Ok(HostConn { write: stream, rx })
    }

    /// Read host frames until the peer closes or the bounded queue backs up; a
    /// full queue means the host is misbehaving, so we drop the connection.
    fn reader_loop(mut stream: VsockStream, tx: &SyncSender<HostMsg>, ping: &Ping) {
        // Host input has no polling deadline; enqueue and terminal read must wake calloop.
        while let Ok(frame) = read_frame(&mut stream) {
            let Ok(msg) = msl_way::remote::parse_host(&frame) else {
                continue;
            };
            match tx.try_send(msg) {
                Ok(()) => ping.ping(),
                Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => break,
            }
        }
        ping.ping();
    }

    fn apply_configure(state: &mut State, cfg: &Configure) {
        debug_assert!(cfg.win != 0, "configure for reserved window id 0");
        let Some(is_popup) = state
            .windows
            .get(&cfg.win)
            .map(msl_way::comp::Win::is_popup)
        else {
            return;
        };
        if is_popup {
            if !state.warned_popup_configure {
                eprintln!("msl-way: ignoring host configure for popup win {}", cfg.win);
                state.warned_popup_configure = true;
            }
            return;
        }
        let Some(toplevel) = state
            .windows
            .get(&cfg.win)
            .and_then(|w| w.toplevel().cloned())
        else {
            return;
        };
        debug_assert!(toplevel.alive(), "configure target toplevel dead");
        toplevel.with_pending_state(|s| {
            let w = i32::try_from(cfg.w).unwrap_or(0);
            let h = i32::try_from(cfg.h).unwrap_or(0);
            s.size = Some((w, h).into());
            s.states.unset(XdgState::Activated);
            for name in &cfg.states {
                match name.as_str() {
                    "activated" => {
                        s.states.set(XdgState::Activated);
                    }
                    "resizing" => {
                        s.states.set(XdgState::Resizing);
                    }
                    "maximized" => {
                        s.states.set(XdgState::Maximized);
                    }
                    _ => {}
                }
            }
        });
        let xdg_serial = u32::from(toplevel.send_configure());
        if let Some(win) = state.windows.get_mut(&cfg.win) {
            win.serials.record(xdg_serial, cfg.serial);
        }
    }

    fn handle_host(state: &mut State, msg: HostMsg) {
        match msg {
            HostMsg::Configure(cfg) => apply_configure(state, &cfg),
            HostMsg::Close(r) => close_window(state, r.win),
            HostMsg::Pointer(p) => inject_pointer(state, &p),
            HostMsg::Key(k) => inject_key(state, &k),
            HostMsg::PresentAck(a) => {
                frames::on_present_ack(state, a.win, a.seq, a.t_recv_ns, a.t_present_ns);
            }
            HostMsg::StatsReq => {
                let json = state.ledger.dump_json();
                state.enqueue(T_STATS, json.into_bytes());
            }
            HostMsg::PopupDismiss(r) => msl_way::popups::dismiss_cascade(state, r.win),
            HostMsg::HelloAck(_) | HostMsg::Unknown(_) => {}
        }
    }

    /// Ask a window to close by the means its shell allows: `xdg_toplevel.close`
    /// for xdg, `WM_DELETE_WINDOW` via `X11Surface::close` for X11 (never a
    /// SIGKILL), and the popup dismissal cascade for popups.
    fn close_window(state: &mut State, win: u32) {
        let Some(entry) = state.windows.get(&win) else {
            return;
        };
        if entry.is_popup() {
            msl_way::popups::dismiss_cascade(state, win);
        } else if let Some(t) = entry.toplevel().cloned() {
            t.send_close();
        } else if let Some(x11) = entry.x11().cloned()
            && let Err(e) = x11.close()
        {
            eprintln!("msl-way: x11 close request failed: {e}");
        }
    }

    fn inject_pointer(state: &mut State, p: &Pointer) {
        input::inject_pointer(state, p);
    }

    fn inject_key(state: &mut State, k: &Key) {
        input::inject_key(state, k);
    }

    fn flush_out(state: &mut State, conn: &mut HostConn) -> io::Result<()> {
        for f in state.out.drain(..) {
            msl_way::remote::write_frame(&mut conn.write, f.msg_type, &f.payload)?;
        }
        Ok(())
    }

    enum Drain {
        Closed,
        Idle,
        More,
    }

    /// Drain at most `DRAIN_BUDGET` host messages per wake so one busy window
    /// cannot starve the compositor; `More` asks the loop to re-arm immediately.
    fn drain_host(state: &mut State, conn: &HostConn) -> Drain {
        for _ in 0..DRAIN_BUDGET {
            match conn.rx.try_recv() {
                Ok(msg) => handle_host(state, msg),
                Err(TryRecvError::Empty) => return Drain::Idle,
                Err(TryRecvError::Disconnected) => return Drain::Closed,
            }
        }
        Drain::More
    }

    const USAGE: &str = "\
Usage: msl-way [OPTIONS]
  --wayland-socket <name>  Wayland socket name (default: auto)
  --vsock-port <port>      host presenter vsock port (default: 5020)
  --layout <layout>        xkb keyboard layout (default: us)
  --list-globals           print the advertised Wayland globals and exit
  --version                print version and exit
  --help                   print this help and exit";

    /// Intercept informational flags before any compositor or xkb initialization
    /// so `--help`/`--version`/`--list-globals` never start serving.
    fn early_exit() -> Option<i32> {
        let mut wants_help = false;
        let mut wants_version = false;
        let mut wants_globals = false;
        for a in std::env::args().skip(1) {
            match a.as_str() {
                "--help" | "-h" => wants_help = true,
                "--version" | "-V" => wants_version = true,
                "--list-globals" => wants_globals = true,
                _ => {}
            }
        }
        if wants_help {
            println!("{USAGE}");
            return Some(0);
        }
        if wants_version {
            println!("msl-way {}", env!("CARGO_PKG_VERSION"));
            return Some(0);
        }
        if wants_globals {
            for g in msl_way::REQUIRED_GLOBALS {
                println!("{g}");
            }
            return Some(0);
        }
        None
    }

    pub fn run() -> i32 {
        if let Some(code) = early_exit() {
            return code;
        }
        let args = parse_args();
        match run_inner(&args) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("msl-way: {e}");
                1
            }
        }
    }

    fn run_inner(args: &Args) -> io::Result<()> {
        let mut event_loop: EventLoop<State> =
            EventLoop::try_new().map_err(|e| io::Error::other(e.to_string()))?;
        let mut display: Display<State> =
            Display::new().map_err(|e| io::Error::other(e.to_string()))?;
        let mut state = build_state(&display, &args.layout)?;
        install_wayland_socket(&event_loop, args)?;
        install_shutdown_signals(&event_loop)?;
        let host_ping = install_host_ping(&event_loop)?;
        spawn_xwayland(&event_loop.handle(), &display)?;
        let listener = bind_vsock(args.vsock_port)?;
        let mut host: Option<HostConn> = None;
        let mut interval = Some(DISCONNECTED_ACCEPT_INTERVAL);
        eprintln!("msl-way: listening on vsock port {}", args.vsock_port);

        loop {
            event_loop
                .dispatch(interval, &mut state)
                .map_err(|e| io::Error::other(e.to_string()))?;
            // Returning here drops the event loop, whose XWayland source unlinks
            // its `/tmp/.X11-unix` socket via `X11Lock::Drop` — the only path
            // that leaves no stale socket after `msl gui stop`.
            if state.shutdown {
                return Ok(());
            }
            let mut immediate = false;
            display.dispatch_clients(&mut state)?;
            if host.is_none()
                && let Some(stream) = accept_host(&listener)?
            {
                match handshake(stream, &mut state, host_ping.clone()) {
                    Ok(conn) => {
                        host = Some(conn);
                        frames::replay_all(&mut state);
                    }
                    Err(e) => eprintln!("msl-way: host handshake failed: {e}"),
                }
            }
            match host.as_ref().map(|conn| drain_host(&mut state, conn)) {
                Some(Drain::Closed) => host = None,
                Some(Drain::More) => immediate = true,
                _ => {}
            }
            let now = state.now_ns();
            frames::poll_pacing(&mut state, now);
            if host.is_none() {
                state.out.clear();
            } else if host
                .as_mut()
                .is_some_and(|conn| flush_out(&mut state, conn).is_err())
            {
                host = None;
            }
            display.flush_clients()?;
            interval = next_dispatch_timeout(&state, host.is_some(), immediate);
        }
    }

    fn install_host_ping(event_loop: &EventLoop<State>) -> io::Result<Ping> {
        let (ping, source) = make_ping()?;
        event_loop
            .handle()
            .insert_source(source, |(), &mut (), _state: &mut State| {})
            .map_err(|e| io::Error::other(e.to_string()))?;
        Ok(ping)
    }

    fn next_dispatch_timeout(state: &State, connected: bool, immediate: bool) -> Option<Duration> {
        if immediate {
            return Some(Duration::ZERO);
        }
        let pacing = state.next_pacing_timeout(state.now_ns());
        if connected {
            pacing
        } else {
            Some(
                pacing
                    .unwrap_or(DISCONNECTED_ACCEPT_INTERVAL)
                    .min(DISCONNECTED_ACCEPT_INTERVAL),
            )
        }
    }

    /// Turn SIGTERM/SIGINT into a flagged clean exit. calloop's signalfd source
    /// blocks the signals on this thread (inherited by the reader thread spawned
    /// later), so the default terminate action never fires and the run loop can
    /// unwind, dropping the `XWayland` socket instead of leaking it on a raw kill.
    fn install_shutdown_signals(event_loop: &EventLoop<State>) -> io::Result<()> {
        use smithay::reexports::calloop::signals::{Signal, Signals};
        let signals = Signals::new(&[Signal::SIGTERM, Signal::SIGINT])
            .map_err(|e| io::Error::other(e.to_string()))?;
        event_loop
            .handle()
            .insert_source(signals, |_event, &mut (), state: &mut State| {
                state.shutdown = true;
            })
            .map_err(|e| io::Error::other(e.to_string()))?;
        Ok(())
    }

    /// Xwayland binds `/tmp/.X11-unix/X<N>` but never creates the directory; a
    /// minimal container often lacks it. Create it sticky world-writable (1777),
    /// the standard, and adopt an existing one.
    fn ensure_x11_unix_dir() -> io::Result<()> {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        let path = "/tmp/.X11-unix";
        match std::fs::DirBuilder::new().mode(0o1777).create(path) {
            Ok(()) => std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o1777)),
            Err(ref e) if e.kind() == io::ErrorKind::AlreadyExists => Ok(()),
            Err(e) => Err(e),
        }
    }

    /// Start a rootless Xwayland and, once it is ready, print its display and
    /// bring up the X11 window manager. The `XWayland` handle lives inside the
    /// event-loop source so its `Drop` (socket unlink, server shutdown) fires on
    /// a clean exit.
    fn spawn_xwayland(
        handle: &smithay::reexports::calloop::LoopHandle<'static, State>,
        display: &Display<State>,
    ) -> io::Result<()> {
        use smithay::xwayland::{X11Wm, XWayland, XWaylandEvent};
        ensure_x11_unix_dir()?;
        let dh = display.handle();
        let (xwayland, client) = XWayland::spawn(
            &dh,
            None,
            std::iter::empty::<(String, String)>(),
            true,
            std::process::Stdio::null(),
            std::process::Stdio::null(),
            |_| {},
        )
        .map_err(|e| io::Error::other(e.to_string()))?;
        let wm_handle = handle.clone();
        handle
            .insert_source(xwayland, move |event, (), state: &mut State| match event {
                XWaylandEvent::Ready {
                    x11_socket,
                    display_number,
                } => {
                    debug_assert!(state.xwm.is_none(), "xwayland readied twice");
                    eprintln!("msl-way: DISPLAY=:{display_number}");
                    match X11Wm::start_wm(wm_handle.clone(), x11_socket, client.clone()) {
                        Ok(wm) => state.xwm = Some(wm),
                        Err(e) => eprintln!("msl-way: X11Wm::start_wm failed: {e}"),
                    }
                }
                XWaylandEvent::Error => eprintln!("msl-way: XWayland failed to start"),
            })
            .map_err(|e| io::Error::other(e.to_string()))?;
        Ok(())
    }

    fn install_wayland_socket(event_loop: &EventLoop<State>, args: &Args) -> io::Result<()> {
        use smithay::wayland::socket::ListeningSocketSource;
        let source = args
            .wayland_socket
            .as_deref()
            .map_or_else(
                ListeningSocketSource::new_auto,
                ListeningSocketSource::with_name,
            )
            .map_err(|e| io::Error::other(e.to_string()))?;
        let name = source.socket_name().to_string_lossy().into_owned();
        eprintln!("msl-way: WAYLAND_DISPLAY={name}");
        event_loop
            .handle()
            .insert_source(source, |stream, &mut (), state: &mut State| {
                let _ = state
                    .dh
                    .insert_client(stream, Arc::new(ClientState::default()));
            })
            .map_err(|e| io::Error::other(e.to_string()))?;
        Ok(())
    }
}
