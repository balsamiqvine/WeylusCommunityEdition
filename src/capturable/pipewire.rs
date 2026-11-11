use std::collections::HashMap;
use std::error::Error;
use std::os::unix::io::AsRawFd;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tracing::{debug, info, trace, warn};

use dbus::{
    arg::{OwnedFd, PropMap, RefArg, Variant},
    blocking::{Proxy, SyncConnection},
    message::{MatchRule, MessageType},
    Message,
};

use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app::AppSink;

use crate::capturable::{Capturable, Geometry, Recorder};
use crate::video::{dmabuf_allowed, DmaBufFrame, PixelProvider, DMABUF_DISABLED};

use crate::capturable::remote_desktop_dbus::{
    OrgFreedesktopPortalRemoteDesktop, OrgFreedesktopPortalRequestResponse,
    OrgFreedesktopPortalScreenCast,
};

#[derive(Debug, Clone, Copy)]
struct PwStreamInfo {
    path: u64,
    source_type: u64,
}

#[derive(Debug)]
pub struct DBusError(String);

impl std::fmt::Display for DBusError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Self(s) = self;
        write!(f, "{}", s)
    }
}

impl Error for DBusError {}

#[derive(Debug)]
pub struct GStreamerError(String);

impl std::fmt::Display for GStreamerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Self(s) = self;
        write!(f, "{}", s)
    }
}

impl Error for GStreamerError {}

#[derive(Clone)]
pub struct PipeWireCapturable {
    // connection needs to be kept alive for recording
    dbus_conn: Arc<SyncConnection>,
    fd: OwnedFd,
    path: u64,
    source_type: u64,
}

impl PipeWireCapturable {
    fn new(conn: Arc<SyncConnection>, fd: OwnedFd, stream: PwStreamInfo) -> Self {
        Self {
            dbus_conn: conn,
            fd,
            path: stream.path,
            source_type: stream.source_type,
        }
    }
}

impl std::fmt::Debug for PipeWireCapturable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "PipeWireCapturable {{dbus: {}, fd: {}, path: {}, source_type: {}}}",
            self.dbus_conn.unique_name(),
            self.fd.as_raw_fd(),
            self.path,
            self.source_type
        )
    }
}

impl Capturable for PipeWireCapturable {
    fn name(&self) -> String {
        let type_str = match self.source_type {
            1 => "Desktop",
            2 => "Window",
            _ => "Unknown",
        };
        format!("Pipewire {}, path: {}", type_str, self.path)
    }

    fn geometry(&self) -> Result<Geometry, Box<dyn Error>> {
        Ok(Geometry::Relative(0.0, 0.0, 1.0, 1.0))
    }

    fn before_input(&mut self) -> Result<(), Box<dyn Error>> {
        Ok(())
    }

    fn recorder(&self, _capture_cursor: bool) -> Result<Box<dyn Recorder>, Box<dyn Error>> {
        Ok(Box::new(PipeWireRecorder::new(
            PwSource::Portal {
                fd: self.fd.clone(),
                path: self.path,
            },
            None,
        )?))
    }
}

/// Frames that reached the appsink (diagnostics).
pub static SAMPLES_ARRIVED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// Where a recorder reads frames from.
#[derive(Clone)]
pub enum PwSource {
    /// A stream granted through the ScreenCast portal (fd to the portal's PipeWire remote).
    Portal { fd: OwnedFd, path: u64 },
    /// A node on the user's own PipeWire daemon, e.g. a Mutter virtual display. Its size is
    /// pinned to `width`x`height`, which for a virtual display also sets the monitor's resolution.
    Node { node: u32, width: u32, height: u32 },
}

pub struct PipeWireRecorder {
    source: PwSource,
    buffer: Option<gst::MappedBuffer<gst::buffer::Readable>>,
    buffer_cropped: Vec<u8>,
    pix_fmt: String,
    is_cropped: bool,
    pipeline: gst::Pipeline,
    appsink: AppSink,
    width: usize,
    height: usize,
    /// Pipeline was built accepting DMA-BUFs (zero-copy).
    dmabuf_mode: bool,
    /// Latest DMA-BUF frame; the sample keeps the buffer (and its fd) alive.
    dmabuf: Option<DmaBufSample>,
    /// `poll_new_frame` already fetched this tick's frame.
    pulled: bool,
    /// Keeps a virtual display alive while recording it; configured once its first frame arrives.
    /// Declared last so it's dropped after the pipeline has stopped.
    virtual_display: Option<crate::capturable::mutter_virtual::MutterVirtualDisplay>,
    virtual_display_configured: bool,
}

struct DmaBufSample {
    _sample: gst::Sample,
    fd: std::os::fd::RawFd,
    width: usize,
    height: usize,
    fourcc: u32,
    modifier: u64,
    offset: usize,
    stride: usize,
}

fn build_pipeline(source: &PwSource, dmabuf: bool) -> Result<(gst::Pipeline, AppSink), Box<dyn Error>> {
    let pipeline = gst::Pipeline::new();

    let src = gst::ElementFactory::make("pipewiresrc").build()?;
    let size = match source {
        PwSource::Portal { fd, path } => {
            src.set_property("fd", &fd.as_raw_fd());
            src.set_property("path", &format!("{path}"));
            String::new()
        }
        PwSource::Node { node, width, height } => {
            src.set_property("path", &format!("{node}"));
            format!(",width={width},height={height}")
        }
    };

    // Enough buffers that the compositor always has a free one to draw into while we encode.
    src.set_property("min-buffers", &4i32);
    // Re-send the last frame once a second when nothing changes, so a restarted encoder (new
    // client, changed settings) gets a picture even on a completely static screen.
    src.set_property("keepalive-time", &1000i32);

    if !dmabuf {
        // For some reason pipewire blocks on destruction of AppSink if this is not set to true,
        // see: https://gitlab.freedesktop.org/pipewire/pipewire/-/issues/982
        // (Copying would defeat zero-copy capture, and the property is deprecated in newer
        // PipeWire versions, so only keep this workaround for the copying path.)
        src.set_property("always-copy", &true);
    }

    let sink = gst::ElementFactory::make("appsink").build()?;
    sink.set_property("drop", &true);
    sink.set_property("max-buffers", &1u32);
    // Hand frames over the moment they arrive. With sync on (the default) the sink waits for each
    // buffer's timestamp on the pipeline clock, which screencast timestamps don't follow, causing
    // stalls of hundreds of milliseconds and bursty, low frame rates.
    sink.set_property("sync", &false);
    // Don't keep an extra reference to the last frame: that's one buffer fewer for the compositor
    // to draw into (it matters with virtual monitors, which only draw into free buffers).
    sink.set_property("enable-last-sample", &false);
    // count frames as they arrive (for WEYLUS_STATS), independent of how often they're pulled
    sink.connect("new-sample", false, |_| {
        SAMPLES_ARRIVED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        Some(gst::FlowReturn::Ok.to_value())
    });
    sink.set_property("emit-signals", &true);

    pipeline.add_many(&[&src, &sink])?;
    src.link(&sink)?;
    let appsink = sink
        .dynamic_cast::<AppSink>()
        .map_err(|_| GStreamerError("Sink element is expected to be an appsink!".into()))?;
    // Prefer DMA-BUFs (frames stay in GPU memory), fall back to frames copied into system
    // memory if the compositor or this machine can't provide them.
    //
    // pipewiresrc drops DMA_DRM caps that don't list explicit drm-formats, so spell out the
    // fourcc:modifier pairs we can import: linear (no modifier suffix) works on every GPU, plus
    // Intel's X- and Y-tiled layouts. If the compositor offers none of these, PipeWire simply
    // negotiates the copied BGRx/RGBx formats instead.
    const DRM_FORMATS: &str = "{ XR24:0x0100000000000002, XR24:0x0100000000000001, XR24, \
                               XB24:0x0100000000000002, XB24:0x0100000000000001, XB24 }";
    let caps: gst::Caps = if dmabuf {
        format!(
            "video/x-raw(memory:DMABuf),format=DMA_DRM,drm-format=(string){DRM_FORMATS}{size}; \
             video/x-raw,format=BGRx{size}; video/x-raw,format=RGBx{size}"
        )
    } else {
        format!("video/x-raw,format=BGRx{size}; video/x-raw,format=RGBx{size}")
    }
    .parse()?;
    appsink.set_caps(Some(&caps));

    pipeline.set_state(gst::State::Playing)?;
    Ok((pipeline, appsink))
}

/// Extract what the encoder needs to import a DMA-BUF frame.
fn dmabuf_sample(sample: gst::Sample) -> Result<DmaBufSample, Box<dyn Error>> {
    let caps = sample
        .caps()
        .ok_or_else(|| GStreamerError("Sample has no caps.".into()))?;
    let s = caps
        .structure(0)
        .ok_or_else(|| GStreamerError("Caps have no structure.".into()))?;
    let width = s.get::<i32>("width")? as usize;
    let height = s.get::<i32>("height")? as usize;
    // e.g. "XR24:0x0100000000000001" (fourcc:modifier), or just "XR24" for linear buffers
    let drm_format = s.get::<String>("drm-format")?;
    let (fourcc_str, modifier) = match drm_format.split_once(':') {
        Some((f, m)) => (f, u64::from_str_radix(m.trim_start_matches("0x"), 16)?),
        None => (drm_format.as_str(), 0),
    };
    let fourcc_bytes: [u8; 4] = fourcc_str
        .as_bytes()
        .try_into()
        .map_err(|_| GStreamerError(format!("Bad DRM format: {drm_format}")))?;
    let fourcc = u32::from_le_bytes(fourcc_bytes);

    let buf = sample
        .buffer()
        .ok_or_else(|| GStreamerError("Sample has no buffer.".into()))?;
    if buf.n_memory() != 1 {
        return Err(Box::new(GStreamerError(format!(
            "Expected a single-plane DMA-BUF, got {} memories.",
            buf.n_memory()
        ))));
    }
    if let Some(crop) = buf.meta::<gstreamer_video::VideoCropMeta>() {
        if crop.rect() != (0, 0, width as u32, height as u32) {
            return Err(Box::new(GStreamerError(
                "Cropped DMA-BUFs are not supported.".into(),
            )));
        }
    }
    let mem = buf.peek_memory(0);
    let fd = mem
        .downcast_memory_ref::<gstreamer_allocators::DmaBufMemory>()
        .ok_or_else(|| GStreamerError("Buffer is not a DMA-BUF.".into()))?
        .fd();
    let (offset, stride) = match buf.meta::<gstreamer_video::VideoMeta>() {
        Some(vm) => (mem.offset() + vm.offset()[0], vm.stride()[0] as usize),
        None => (mem.offset(), width * 4),
    };
    Ok(DmaBufSample {
        fd,
        width,
        height,
        fourcc,
        modifier,
        offset,
        stride,
        _sample: sample,
    })
}

impl PipeWireRecorder {
    pub fn new(
        source: PwSource,
        virtual_display: Option<crate::capturable::mutter_virtual::MutterVirtualDisplay>,
    ) -> Result<Self, Box<dyn Error>> {
        let dmabuf_mode = dmabuf_allowed();
        let (pipeline, appsink) = build_pipeline(&source, dmabuf_mode)?;
        Ok(Self {
            source,
            virtual_display,
            virtual_display_configured: false,
            pipeline,
            appsink,
            buffer: None,
            pix_fmt: "".into(),
            width: 0,
            height: 0,
            buffer_cropped: vec![],
            is_cropped: false,
            dmabuf_mode,
            dmabuf: None,
            pulled: false,
        })
    }

    /// Zero-copy didn't work out: rebuild the pipeline so PipeWire hands us copied frames.
    fn fall_back_to_copying(&mut self) -> Result<(), Box<dyn Error>> {
        info!("Switching screen capture to copying mode.");
        self.dmabuf = None;
        // Stop the old pipeline before creating a new one, see
        // https://gitlab.freedesktop.org/pipewire/pipewire/-/issues/986
        if let Err(err) = self.pipeline.set_state(gst::State::Null) {
            warn!("Failed to stop GStreamer pipeline: {}.", err);
        }
        let (pipeline, appsink) = build_pipeline(&self.source, false)?;
        self.pipeline = pipeline;
        self.appsink = appsink;
        self.dmabuf_mode = false;
        Ok(())
    }
}

impl PipeWireRecorder {
    /// Fetch the newest frame from PipeWire, if any, and store it. Returns whether a new frame
    /// arrived (GNOME only sends one when something on screen changed).
    fn pull(&mut self) -> Result<bool, Box<dyn Error>> {
        if self.dmabuf_mode && !dmabuf_allowed() {
            self.fall_back_to_copying()?;
        }
        if let Some(sample) = self
            .appsink
            .try_pull_sample(gst::ClockTime::from_mseconds(16))
        {
            let is_dmabuf = sample
                .caps()
                .and_then(|c| c.features(0).map(|f| f.contains("memory:DMABuf")))
                .unwrap_or(false);
            if is_dmabuf {
                match dmabuf_sample(sample) {
                    Ok(d) => {
                        self.dmabuf = Some(d);
                        self.buffer = None;
                    }
                    Err(err) => {
                        warn!("Can't use DMA-BUF frame ({err}), falling back to copying.");
                        DMABUF_DISABLED.store(true, std::sync::atomic::Ordering::Relaxed);
                        self.fall_back_to_copying()?;
                        return Err(err);
                    }
                }
                return Ok(true);
            }
            self.dmabuf = None;
            let cap = sample.caps().unwrap().structure(0).unwrap();
            let w: i32 = cap.value("width")?.get()?;
            let h: i32 = cap.value("height")?.get()?;
            self.pix_fmt = cap.value("format")?.get()?;
            let w = w as usize;
            let h = h as usize;
            let buf = sample
                .buffer_owned()
                .ok_or_else(|| GStreamerError("Failed to get owned buffer.".into()))?;
            let mut crop = buf
                .meta::<gstreamer_video::VideoCropMeta>()
                .map(|m| m.rect());
            // only crop if necessary
            if Some((0, 0, w as u32, h as u32)) == crop {
                crop = None;
            }
            let buf = buf
                .into_mapped_buffer_readable()
                .map_err(|_| GStreamerError("Failed to map buffer.".into()))?;
            let buf_size = buf.size();
            // BGRx is 4 bytes per pixel
            if buf_size != (w * h * 4) {
                // for some reason the width and height of the caps do not guarantee correct buffer
                // size, so ignore those buffers, see:
                // https://gitlab.freedesktop.org/pipewire/pipewire/-/issues/985
                trace!(
                    "Size of mapped buffer: {} does NOT match size of capturable {}x{}@BGRx, \
                    dropping it!",
                    buf_size,
                    w,
                    h
                );
            } else {
                // Copy region specified by crop into self.buffer_cropped
                // TODO: Figure out if ffmpeg provides a zero copy alternative
                if let Some((x_off, y_off, w_crop, h_crop)) = crop {
                    let x_off = x_off as usize;
                    let y_off = y_off as usize;
                    let w_crop = w_crop as usize;
                    let h_crop = h_crop as usize;
                    self.buffer_cropped.clear();
                    let data = buf.as_slice();
                    // BGRx is 4 bytes per pixel
                    self.buffer_cropped.reserve(w_crop * h_crop * 4);
                    for y in y_off..(y_off + h_crop) {
                        let i = 4 * (w * y + x_off);
                        self.buffer_cropped.extend(&data[i..i + 4 * w_crop]);
                    }
                    self.width = w_crop;
                    self.height = h_crop;
                } else {
                    self.width = w;
                    self.height = h;
                }
                self.is_cropped = crop.is_some();
                self.buffer = Some(buf);
                return Ok(true);
            }
        } else {
            trace!("No new buffer available, falling back to previous one.");
        }
        Ok(false)
    }
}

impl PipeWireRecorder {
    fn pull_and_configure(&mut self) -> Result<bool, Box<dyn Error>> {
        let new = self.pull()?;
        if new && !self.virtual_display_configured {
            if let Some(display) = self.virtual_display.as_mut() {
                // The monitor only appears once PipeWire has negotiated its size, so this can
                // take a few frames.
                match display.configure() {
                    Ok(()) => self.virtual_display_configured = true,
                    Err(err) => debug!("Virtual display not ready yet: {err}"),
                }
            }
        }
        Ok(new)
    }
}

impl Recorder for PipeWireRecorder {
    fn release_frame(&mut self) {
        // Hand the DMA-BUF back to the compositor right away. With a virtual monitor, Mutter only
        // draws when it has a free buffer, so holding one starves it. If the encoder later needs
        // a frame on a static screen, pipewiresrc's keepalive re-sends the last one.
        self.dmabuf = None;
    }

    fn poll_new_frame(&mut self) -> bool {
        self.pulled = true;
        match self.pull_and_configure() {
            Ok(new) => new,
            Err(err) => {
                warn!("Error capturing screen: {err}");
                false
            }
        }
    }

    fn capture(&mut self) -> Result<PixelProvider<'_>, Box<dyn Error>> {
        if !self.pulled {
            self.pull_and_configure()?;
        }
        self.pulled = false;
        if let Some(d) = self.dmabuf.as_ref() {
            return Ok(PixelProvider::DmaBuf(DmaBufFrame {
                width: d.width,
                height: d.height,
                // Safety: the fd is owned by the sample stored alongside it in self.dmabuf
                fd: unsafe { std::os::fd::BorrowedFd::borrow_raw(d.fd) },
                fourcc: d.fourcc,
                modifier: d.modifier,
                offset: d.offset,
                stride: d.stride,
            }));
        }
        if self.buffer.is_none() {
            return Err(Box::new(GStreamerError("No buffer available!".into())));
        }
        let buf = if self.is_cropped {
            self.buffer_cropped.as_slice()
        } else {
            self.buffer.as_ref().unwrap().as_slice()
        };
        match self.pix_fmt.as_str() {
            "BGRx" => Ok(PixelProvider::BGR0(self.width, self.height, buf)),
            "RGBx" => Ok(PixelProvider::RGB0(self.width, self.height, buf)),
            _ => unreachable!(),
        }
    }
}

impl Drop for PipeWireRecorder {
    fn drop(&mut self) {
        // release our buffers before stopping, so PipeWire isn't waiting on them
        self.dmabuf = None;
        self.buffer = None;
        if let Err(err) = self.pipeline.set_state(gst::State::Null) {
            warn!("Failed to stop GStreamer pipeline: {}.", err);
        }
    }
}

fn handle_response<F>(
    portal: Proxy<&SyncConnection>,
    path: dbus::Path<'static>,
    context: Arc<Mutex<CallBackContext>>,
    mut f: F,
) -> Result<dbus::channel::Token, dbus::Error>
where
    F: FnMut(
            OrgFreedesktopPortalRequestResponse,
            Proxy<&SyncConnection>,
            &Message,
            Arc<Mutex<CallBackContext>>,
        ) -> Result<(), Box<dyn Error>>
        + Send
        + Sync
        + 'static,
{
    let mut m = MatchRule::new();
    m.path = Some(path);
    m.msg_type = Some(MessageType::Signal);
    m.sender = Some("org.freedesktop.portal.Desktop".into());
    m.interface = Some("org.freedesktop.portal.Request".into());
    portal
        .connection
        .add_match(m, move |r: OrgFreedesktopPortalRequestResponse, c, m| {
            let portal = get_portal(c);
            debug!("Response from DBus: response: {:?}, message: {:?}", r, m);
            match r.response {
                0 => {}
                1 => {
                    context.lock().unwrap().failure = true;
                    warn!("DBus response: User cancelled interaction.");
                    return true;
                }
                c => {
                    context.lock().unwrap().failure = true;
                    warn!("DBus response: Unknown error, code: {}.", c);
                    return true;
                }
            }
            if let Err(err) = f(r, portal, m, context.clone()) {
                context.lock().unwrap().failure = true;
                warn!("Error requesting screen capture via dbus: {}", err);
            }
            true
        })
}

fn get_portal(conn: &SyncConnection) -> Proxy<'_, &SyncConnection> {
    conn.with_proxy(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        Duration::from_millis(1000),
    )
}

fn streams_from_response(response: &OrgFreedesktopPortalRequestResponse) -> Vec<PwStreamInfo> {
    (move || {
        Some(
            response
                .results
                .get("streams")?
                .as_iter()?
                .next()?
                .as_iter()?
                .filter_map(|stream| {
                    let mut itr = stream.as_iter()?;
                    let path = itr.next()?.as_u64()?;
                    let (keys, values): (Vec<(usize, &dyn RefArg)>, Vec<(usize, &dyn RefArg)>) =
                        itr.next()?
                            .as_iter()?
                            .enumerate()
                            .partition(|(i, _)| i % 2 == 0);
                    let attributes = keys
                        .iter()
                        .filter_map(|(_, key)| Some(key.as_str()?.to_owned()))
                        .zip(
                            values
                                .iter()
                                .map(|(_, arg)| *arg)
                                .collect::<Vec<&dyn RefArg>>(),
                        )
                        .collect::<HashMap<String, &dyn RefArg>>();
                    Some(PwStreamInfo {
                        path,
                        source_type: attributes
                            .get("source_type")
                            .map_or(Some(0), |v| v.as_u64())?,
                    })
                })
                .collect::<Vec<PwStreamInfo>>(),
        )
    })()
    .unwrap_or_default()
}

// mostly inspired by https://gitlab.gnome.org/snippets/19 and
// https://gitlab.gnome.org/-/snippets/39
struct CallBackContext {
    capture_cursor: bool,
    session: dbus::Path<'static>,
    streams: Vec<PwStreamInfo>,
    fd: Option<OwnedFd>,
    restore_token: Option<String>,
    has_remote_desktop: bool,
    failure: bool,
}

fn on_create_session_response(
    r: OrgFreedesktopPortalRequestResponse,
    portal: Proxy<&SyncConnection>,
    _msg: &Message,
    context: Arc<Mutex<CallBackContext>>,
) -> Result<(), Box<dyn Error>> {
    debug!("on_create_session_response");
    let session: dbus::Path = r
        .results
        .get("session_handle")
        .ok_or_else(|| {
            DBusError(format!(
                "Failed to obtain session_handle from response: {:?}",
                r
            ))
        })?
        .as_str()
        .ok_or_else(|| DBusError("Failed to convert session_handle to string.".into()))?
        .to_string()
        .into();

    context.lock().unwrap().session = session.clone();
    if context.lock().unwrap().has_remote_desktop {
        select_devices(portal, context)
    } else {
        select_sources(portal, context)
    }
}

fn select_devices(
    portal: Proxy<&SyncConnection>,
    context: Arc<Mutex<CallBackContext>>,
) -> Result<(), Box<dyn Error>> {
    let mut args: PropMap = HashMap::new();
    let t: usize = rand::random();
    args.insert(
        "handle_token".to_string(),
        Variant(Box::new(format!("weylus{t}"))),
    );

    // TODO
    //args.insert(
    //    "restore_token".to_string(),
    //    Variant(Box::new(format!("weylus{t}"))),
    //);

    // persist modes:
    // 0: Do not persist (default)
    // 1: Permissions persist as long as the application is running
    // 2: Permissions persist until explicitly revoked
    args.insert("persist_mode".to_string(), Variant(Box::new(2 as u32)));

    // device types
    // 1: KEYBOARD
    // 2: POINTER
    // 4: TOUCHSCREEN
    let device_types = portal.available_device_types()?;
    debug!("Available device types: {device_types}.");
    args.insert("types".to_string(), Variant(Box::new(device_types)));

    let path = portal.select_devices(context.lock().unwrap().session.clone(), args)?;
    handle_response(portal, path, context, |_, portal, _, context| {
        select_sources(portal, context)
    })?;
    Ok(())
}

fn select_sources(
    portal: Proxy<&SyncConnection>,
    context: Arc<Mutex<CallBackContext>>,
) -> Result<(), Box<dyn Error>> {
    debug!("select_sources");
    let mut args: PropMap = HashMap::new();

    let t: usize = rand::random();
    args.insert(
        "handle_token".to_string(),
        Variant(Box::new(format!("weylus{t}"))),
    );
    // https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html#org-freedesktop-portal-screencast-selectsources
    // allow multiple sources
    args.insert("multiple".into(), Variant(Box::new(true)));

    // 1: MONITOR
    // 2: WINDOW
    // 4: VIRTUAL
    let source_types = portal.available_source_types()?;
    debug!("Available source types: {source_types}.");
    args.insert("types".into(), Variant(Box::new(source_types)));

    let capture_cursor = context.lock().unwrap().capture_cursor;
    // 1: Hidden. The cursor is not part of the screen cast stream.
    // 2: Embedded: The cursor is embedded as part of the stream buffers.
    // 4: Metadata: The cursor is not part of the screen cast stream, but sent as PipeWire stream metadata.
    let cursor_mode = if capture_cursor { 2u32 } else { 1u32 };

    let is_plasma = std::env::var("DESKTOP_SESSION").map_or(false, |s| s.contains("plasma"));
    if is_plasma && capture_cursor {
        // Warn the user if capturing the cursor is tried on kde as this can crash
        // kwin_wayland and tear down the plasma desktop, see:
        // https://bugs.kde.org/show_bug.cgi?id=435042
        warn!(
            "You are attempting to capture the cursor under KDE Plasma, this may crash your \
                    desktop, see https://bugs.kde.org/show_bug.cgi?id=435042 for details! \
                    You have been warned."
        );
    }
    args.insert("cursor_mode".into(), Variant(Box::new(cursor_mode)));

    let path = portal.select_sources(context.lock().unwrap().session.clone(), args)?;
    handle_response(portal, path, context, on_select_sources_response)?;
    Ok(())
}

fn on_select_sources_response(
    _r: OrgFreedesktopPortalRequestResponse,
    portal: Proxy<&SyncConnection>,
    _msg: &Message,
    context: Arc<Mutex<CallBackContext>>,
) -> Result<(), Box<dyn Error>> {
    debug!("on_select_sources_response");
    let mut args: PropMap = HashMap::new();
    let t: usize = rand::random();
    args.insert(
        "handle_token".to_string(),
        Variant(Box::new(format!("weylus{t}"))),
    );
    let path = if context.lock().unwrap().has_remote_desktop {
        OrgFreedesktopPortalRemoteDesktop::start(
            &portal,
            context.lock().unwrap().session.clone(),
            "",
            args,
        )?
    } else {
        OrgFreedesktopPortalScreenCast::start(
            &portal,
            context.lock().unwrap().session.clone(),
            "",
            args,
        )?
    };
    handle_response(portal, path, context, on_start_response)?;
    Ok(())
}

fn on_start_response(
    r: OrgFreedesktopPortalRequestResponse,
    portal: Proxy<&SyncConnection>,
    _msg: &Message,
    context: Arc<Mutex<CallBackContext>>,
) -> Result<(), Box<dyn Error>> {
    debug!("on_start_response");
    let mut context = context.lock().unwrap();
    context.streams.append(&mut streams_from_response(&r));
    let session = context.session.clone();
    context
        .fd
        .replace(portal.open_pipe_wire_remote(session.clone(), HashMap::new())?);
    if let Some(Some(t)) = r.results.get("restore_token").map(|t| t.as_str()) {
        context.restore_token = Some(t.to_string());
    }
    dbg!(&context.restore_token);
    if context.has_remote_desktop {
        debug!("Remote Desktop Session started");
    } else {
        debug!("Screen Cast Session started");
    }
    Ok(())
}

fn request_remote_desktop(
    capture_cursor: bool,
) -> Result<(SyncConnection, OwnedFd, Vec<PwStreamInfo>), Box<dyn Error>> {
    let conn = SyncConnection::new_session()?;
    let portal = get_portal(&conn);

    // Disabled for KDE plasma due to https://bugs.kde.org/show_bug.cgi?id=484996
    // List of supported DEs: https://wiki.archlinux.org/title/XDG_Desktop_Portal#List_of_backends_and_interfaces
    let has_remote_desktop =
        std::env::var("DESKTOP_SESSION").map_or(false, |s| s.contains("gnome"));

    let context = CallBackContext {
        capture_cursor,
        session: Default::default(),
        streams: Default::default(),
        fd: None,
        restore_token: None,
        has_remote_desktop,
        failure: false,
    };
    let context = Arc::new(Mutex::new(context));

    let mut args: PropMap = HashMap::new();
    let t1: usize = rand::random();
    let t2: usize = rand::random();
    args.insert(
        "session_handle_token".to_string(),
        Variant(Box::new(format!("weylus{t1}"))),
    );
    args.insert(
        "handle_token".to_string(),
        Variant(Box::new(format!("weylus{t2}"))),
    );
    let path = if has_remote_desktop {
        OrgFreedesktopPortalRemoteDesktop::create_session(&portal, args)?
    } else {
        OrgFreedesktopPortalScreenCast::create_session(&portal, args)?
    };
    handle_response(portal, path, context.clone(), on_create_session_response)?;

    // wait 3 minutes for user interaction
    for _ in 0..1800 {
        conn.process(Duration::from_millis(100))?;
        let context = context.lock().unwrap();
        // Once we got a file descriptor we are done!
        if context.fd.is_some() {
            break;
        }

        if context.failure {
            break;
        }
    }
    let context = context.lock().unwrap();
    if context.fd.is_some() && !context.streams.is_empty() {
        Ok((conn, context.fd.clone().unwrap(), context.streams.clone()))
    } else {
        Err(Box::new(DBusError(
            "Failed to obtain screen capture.".into(),
        )))
    }
}

pub fn get_capturables(capture_cursor: bool) -> Result<Vec<PipeWireCapturable>, Box<dyn Error>> {
    let (conn, fd, streams) = request_remote_desktop(capture_cursor)?;
    let conn = Arc::new(conn);
    Ok(streams
        .into_iter()
        .map(|s| PipeWireCapturable::new(conn.clone(), fd.clone(), s))
        .collect())
}
