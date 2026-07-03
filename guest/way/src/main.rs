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

    use smithay::input::keyboard::XkbConfig;
    use smithay::input::{Seat, SeatState};
    use smithay::reexports::calloop::EventLoop;
    use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel::State as XdgState;
    use smithay::reexports::wayland_server::Display;
    use smithay::wayland::compositor::CompositorState;
    use smithay::wayland::shell::xdg::XdgShellState;
    use smithay::wayland::shm::ShmState;
    use vsock::VsockStream;

    use msl_way::comp::{ClientState, State};
    use msl_way::ledger::Ledger;
    use msl_way::remote::{
        Configure, Hello, HelloAck, HostMsg, Key, PROTOCOL_VERSION, Pointer, T_HELLO, T_HELLO_ACK,
        T_STATS, accept_host, bind_vsock, from_json_frame, read_frame, write_json,
    };
    use msl_way::{frames, input};

    const DEFAULT_VSOCK_PORT: u32 = 5020;
    const DISPATCH_INTERVAL: Duration = Duration::from_millis(8);
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

    fn build_state(display: &Display<State>, layout: &str) -> io::Result<State> {
        debug_assert!(!layout.is_empty(), "keyboard layout must be non-empty");
        let dh = display.handle();
        let compositor = CompositorState::new::<State>(&dh);
        let shm = ShmState::new::<State>(&dh, Vec::new());
        let xdg = XdgShellState::new::<State>(&dh);
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
            windows: HashMap::new(),
            surface_win: HashMap::new(),
            focus: None,
            next_win: 1,
            seq: 0,
            scale: 1.0,
            refresh_hz: 60,
            epoch: Instant::now(),
            ledger: Ledger::new(),
            out: Vec::new(),
            dropped_input: 0,
        })
    }

    fn handshake(mut stream: VsockStream, state: &mut State) -> io::Result<HostConn> {
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
        let ack: HelloAck = from_json_frame(&frame.payload)?;
        if ack.version != PROTOCOL_VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "protocol version mismatch",
            ));
        }
        state.scale = if ack.scale > 0.0 { ack.scale } else { 1.0 };
        state.refresh_hz = ack.refresh_hz.max(1);
        let reader = stream.try_clone()?;
        let (tx, rx) = mpsc::sync_channel(HOST_QUEUE_CAP);
        thread::spawn(move || reader_loop(reader, &tx));
        Ok(HostConn { write: stream, rx })
    }

    /// Read host frames until the peer closes or the bounded queue backs up; a
    /// full queue means the host is misbehaving, so we drop the connection.
    fn reader_loop(mut stream: VsockStream, tx: &SyncSender<HostMsg>) {
        while let Ok(frame) = read_frame(&mut stream) {
            let Ok(msg) = msl_way::remote::parse_host(&frame) else {
                continue;
            };
            match tx.try_send(msg) {
                Ok(()) => {}
                Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => break,
            }
        }
    }

    fn apply_configure(state: &State, cfg: &Configure) {
        debug_assert!(cfg.win != 0, "configure for reserved window id 0");
        let Some(win) = state.windows.get(&cfg.win) else {
            return;
        };
        let toplevel = win.toplevel.clone();
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
        toplevel.send_configure();
    }

    fn handle_host(state: &mut State, msg: HostMsg) {
        match msg {
            HostMsg::Configure(cfg) => apply_configure(state, &cfg),
            HostMsg::Close(r) => {
                if let Some(w) = state.windows.get(&r.win) {
                    w.toplevel.send_close();
                }
            }
            HostMsg::Pointer(p) => inject_pointer(state, &p),
            HostMsg::Key(k) => inject_key(state, &k),
            HostMsg::PresentAck(a) => {
                frames::on_present_ack(state, a.win, a.seq, a.t_recv_ns, a.t_present_ns);
            }
            HostMsg::StatsReq => {
                let json = state.ledger.dump_json();
                state.enqueue(T_STATS, json.into_bytes());
            }
            HostMsg::HelloAck(_) | HostMsg::Unknown(_) => {}
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

    pub fn run() -> i32 {
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
        let listener = bind_vsock(args.vsock_port)?;
        let mut host: Option<HostConn> = None;
        let mut interval = DISPATCH_INTERVAL;
        eprintln!("msl-way: listening on vsock port {}", args.vsock_port);

        loop {
            event_loop
                .dispatch(Some(interval), &mut state)
                .map_err(|e| io::Error::other(e.to_string()))?;
            interval = DISPATCH_INTERVAL;
            display.dispatch_clients(&mut state)?;
            if host.is_none()
                && let Some(stream) = accept_host(&listener)?
            {
                match handshake(stream, &mut state) {
                    Ok(conn) => {
                        host = Some(conn);
                        frames::replay_all(&mut state);
                    }
                    Err(e) => eprintln!("msl-way: host handshake failed: {e}"),
                }
            }
            match host.as_ref().map(|conn| drain_host(&mut state, conn)) {
                Some(Drain::Closed) => host = None,
                Some(Drain::More) => interval = Duration::ZERO,
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
        }
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
