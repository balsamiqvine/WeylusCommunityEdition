//! A virtual monitor created through GNOME Mutter's ScreenCast API ("RecordVirtual"), so a client
//! such as an iPad can be used as an extra screen at its own native resolution instead of
//! mirroring (and upscaling) an existing monitor.
//!
//! While the virtual display exists, Weylus' tablet and touchscreen devices are mapped to it, so
//! pen and touch input land on the virtual screen; the mapping is undone when it goes away.
//! Mutter's display configuration (e.g. the monitor's scale) is never touched, see `configure`.

use std::error::Error;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use dbus::arg::{cast, PropMap, Variant};
use dbus::blocking::SyncConnection;
use dbus::message::MatchRule;
use dbus::Path;
use tracing::{info, warn};

use crate::capturable::pipewire::{PipeWireRecorder, PwSource};
use crate::capturable::{Capturable, Geometry, Recorder};

/// vendor:product of Weylus' uinput devices, see lib/linux/uinput.c
const DEVICE_ID: &str = "1701:1701";
const TIMEOUT: Duration = Duration::from_secs(5);

// org.gnome.Mutter.DisplayConfig.GetCurrentState
type MonitorIds = (String, String, String, String); // connector, vendor, product, serial
type Mode = (String, i32, i32, f64, f64, Vec<f64>, PropMap); // id, w, h, refresh, pref. scale, scales, props
type Monitor = (MonitorIds, Vec<Mode>, PropMap);
type LogicalMonitor = (i32, i32, f64, u32, bool, Vec<MonitorIds>, PropMap);
type State = (u32, Vec<Monitor>, Vec<LogicalMonitor>, PropMap);

fn current_state(conn: &SyncConnection) -> Result<State, Box<dyn Error>> {
    let proxy = conn.with_proxy(
        "org.gnome.Mutter.DisplayConfig",
        "/org/gnome/Mutter/DisplayConfig",
        TIMEOUT,
    );
    Ok(proxy.method_call("org.gnome.Mutter.DisplayConfig", "GetCurrentState", ())?)
}

fn current_mode(monitor: &Monitor) -> Option<&Mode> {
    monitor.1.iter().find(|m| {
        m.6.get("is-current")
            .and_then(|v| cast::<bool>(&v.0).copied())
            .unwrap_or(false)
    })
}

/// Point Weylus' tablet and touchscreen devices at a monitor, or back to automatic (`None`).
fn map_input_devices(monitor: Option<(&str, &str, &str)>) {
    for (schema, dir) in [
        ("org.gnome.desktop.peripherals.tablet", "tablets"),
        ("org.gnome.desktop.peripherals.touchscreen", "touchscreens"),
    ] {
        let path = format!("{schema}:/org/gnome/desktop/peripherals/{dir}/{DEVICE_ID}/");
        let result = match monitor {
            Some((vendor, product, serial)) => Command::new("gsettings")
                .args([
                    "set",
                    &path,
                    "output",
                    &format!("['{vendor}', '{product}', '{serial}']"),
                ])
                .status(),
            None => Command::new("gsettings").args(["reset", &path, "output"]).status(),
        };
        match result {
            Ok(s) if s.success() => {}
            Ok(s) => warn!("gsettings exited with {s} while mapping {dir} to the virtual display"),
            Err(err) => warn!("Failed to run gsettings to map {dir}: {err}"),
        }
    }
}

pub struct MutterVirtualDisplay {
    conn: SyncConnection,
    session: Path<'static>,
    /// Connectors that existed before, to recognise the new virtual monitor.
    known_connectors: Vec<String>,
    mapped: bool,
}

impl MutterVirtualDisplay {
    /// Create the virtual monitor's screencast. Returns the display and the PipeWire node to read
    /// it from. The monitor itself appears once a consumer negotiates a size with that node.
    /// `cursor_mode`: 0 hidden, 1 embedded in the video, 2 metadata.
    pub fn create(cursor_mode: u32) -> Result<(Self, u32), Box<dyn Error>> {
        let conn = SyncConnection::new_session()?;
        let known_connectors = current_state(&conn)?
            .1
            .iter()
            .map(|m| (m.0).0.clone())
            .collect();

        let screencast = conn.with_proxy(
            "org.gnome.Mutter.ScreenCast",
            "/org/gnome/Mutter/ScreenCast",
            TIMEOUT,
        );
        let (session,): (Path<'static>,) = screencast.method_call(
            "org.gnome.Mutter.ScreenCast",
            "CreateSession",
            (PropMap::new(),),
        )?;
        let session_proxy = conn.with_proxy("org.gnome.Mutter.ScreenCast", session.clone(), TIMEOUT);
        let mut props = PropMap::new();
        props.insert("cursor-mode".into(), Variant(Box::new(cursor_mode)));
        props.insert("is-platform".into(), Variant(Box::new(true)));
        let (stream,): (Path<'static>,) = session_proxy.method_call(
            "org.gnome.Mutter.ScreenCast.Session",
            "RecordVirtual",
            (props,),
        )?;

        let node: Arc<Mutex<Option<u32>>> = Arc::new(Mutex::new(None));
        let node_cb = node.clone();
        let rule = MatchRule::new_signal("org.gnome.Mutter.ScreenCast.Stream", "PipeWireStreamAdded")
            .with_path(stream);
        let token = conn.add_match(rule, move |(id,): (u32,), _, _| {
            *node_cb.lock().unwrap() = Some(id);
            true
        })?;
        session_proxy.method_call::<(), _, _, _>("org.gnome.Mutter.ScreenCast.Session", "Start", ())?;

        let display = Self {
            conn,
            session,
            known_connectors,
            mapped: false,
        };
        let deadline = Instant::now() + TIMEOUT;
        while node.lock().unwrap().is_none() && Instant::now() < deadline {
            display.conn.process(Duration::from_millis(100))?;
        }
        display.conn.remove_match(token)?;
        let node = node
            .lock()
            .unwrap()
            .ok_or("Mutter did not start the virtual display's stream in time")?;
        Ok((display, node))
    }

    /// Once the monitor exists: map pen and touch input to it.
    ///
    /// The monitor's scale is deliberately left alone. Changing Mutter's display configuration
    /// while a virtual monitor is being recorded (ApplyMonitorsConfig, even a no-op) makes Mutter
    /// 50 deliver only a few frames per second for it, and combined with restarting the stream it
    /// crashed gnome-shell. Clients that want bigger UI request a smaller display and upscale it.
    pub fn configure(&mut self) -> Result<(), Box<dyn Error>> {
        let (_serial, monitors, _logical, _props) = current_state(&self.conn)?;
        let virt = monitors
            .iter()
            .find(|m| !self.known_connectors.contains(&(m.0).0))
            .ok_or("Virtual monitor has not appeared yet")?;
        let ids = &virt.0;
        let size = current_mode(virt).map(|m| (m.1, m.2)).unwrap_or((0, 0));
        map_input_devices(Some((&ids.1, &ids.2, &ids.3)));
        self.mapped = true;
        info!(
            "Virtual display {} ({}x{}) ready; pen and touch mapped to it.",
            ids.0, size.0, size.1
        );
        Ok(())
    }
}

impl Drop for MutterVirtualDisplay {
    fn drop(&mut self) {
        if self.mapped {
            map_input_devices(None);
        }
        let proxy = self.conn.with_proxy("org.gnome.Mutter.ScreenCast", self.session.clone(), TIMEOUT);
        if let Err(err) =
            proxy.method_call::<(), _, _, _>("org.gnome.Mutter.ScreenCast.Session", "Stop", ())
        {
            warn!("Failed to stop the virtual display: {err}");
        }
    }
}

/// An extra screen created on demand at the client's resolution.
#[derive(Clone)]
pub struct VirtualDisplayCapturable {
    pub width: u32,
    pub height: u32,
}

impl Capturable for VirtualDisplayCapturable {
    fn name(&self) -> String {
        format!("Virtual display {}x{}", self.width, self.height)
    }

    fn geometry(&self) -> Result<Geometry, Box<dyn Error>> {
        // input devices are mapped to this monitor as a whole
        Ok(Geometry::Relative(0.0, 0.0, 1.0, 1.0))
    }

    fn before_input(&mut self) -> Result<(), Box<dyn Error>> {
        Ok(())
    }

    fn recorder(&self, capture_cursor: bool) -> Result<Box<dyn Recorder>, Box<dyn Error>> {
        let (display, node) =
            MutterVirtualDisplay::create(if capture_cursor { 1 } else { 0 })?;
        Ok(Box::new(PipeWireRecorder::new(
            PwSource::Node {
                node,
                width: self.width,
                height: self.height,
            },
            Some(display),
        )?))
    }
}
