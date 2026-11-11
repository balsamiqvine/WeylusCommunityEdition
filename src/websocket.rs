use fastwebsockets::{FragmentCollectorRead, Frame, OpCode, WebSocket, WebSocketError};
use hyper::upgrade::Upgraded;
use hyper_util::rt::TokioIo;
use std::convert::Infallible;
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{mpsc, Arc};
use std::thread::{spawn, JoinHandle};
use std::time::{Duration, Instant};
use tokio::sync::mpsc::channel;
use tracing::{error, info, trace, warn};

use crate::capturable::{get_capturables, Capturable, Recorder};
use crate::input::device::{InputDevice, InputDeviceType};
use crate::protocol::{
    ClientConfiguration, KeyboardEvent, MessageInbound, MessageOutbound, PointerEvent,
    WeylusReceiver, WeylusSender, WheelEvent,
};

use crate::cerror::CErrorCode;
use crate::video::{EncoderOptions, VideoEncoder};

struct VideoConfig {
    capturable: Box<dyn Capturable>,
    capture_cursor: bool,
    max_width: usize,
    max_height: usize,
    frame_rate: f64,
    keyframe_interval: u32,
    quality_qp: u32,
}

enum VideoCommands {
    Start(VideoConfig),
    Pause,
    Resume,
    Restart,
}

fn send_message<S>(sender: &mut S, message: MessageOutbound)
where
    S: WeylusSender,
{
    if let Err(err) = sender.send_message(message) {
        warn!("Failed to send message to client: {err}");
    }
}

pub struct WeylusClientHandler<S, R, FnUInput> {
    sender: S,
    receiver: Option<R>,
    video_sender: mpsc::Sender<VideoCommands>,
    input_device: Option<Box<dyn InputDevice>>,
    capturables: Vec<Box<dyn Capturable>>,
    on_uinput_inaccessible: FnUInput,
    config: WeylusClientConfig,
    #[cfg(target_os = "linux")]
    capture_cursor: bool,
    client_name: Option<String>,
    video_thread: JoinHandle<()>,
}

#[derive(Clone, Copy)]
pub struct WeylusClientConfig {
    pub encoder_options: EncoderOptions,
    #[cfg(target_os = "linux")]
    pub wayland_support: bool,
    pub no_gui: bool,
}

impl<S, R, FnUInput> WeylusClientHandler<S, R, FnUInput> {
    pub fn new(
        sender: S,
        receiver: R,
        on_uinput_inaccessible: FnUInput,
        config: WeylusClientConfig,
    ) -> Self
    where
        R: WeylusReceiver,
        S: WeylusSender + Clone + Send + Sync + 'static,
    {
        let (video_sender, video_receiver) = mpsc::channel::<VideoCommands>();
        let video_thread = {
            let sender = sender.clone();
            // offload creating the videostream to another thread to avoid blocking the thread that
            // is receiving messages from the websocket
            spawn(move || handle_video(video_receiver, sender, config.encoder_options))
        };

        Self {
            sender,
            receiver: Some(receiver),
            video_sender,
            input_device: None,
            capturables: vec![],
            on_uinput_inaccessible,
            config,
            #[cfg(target_os = "linux")]
            capture_cursor: false,
            client_name: None,
            video_thread,
        }
    }

    pub fn run(mut self)
    where
        R: WeylusReceiver,
        S: WeylusSender + Clone + Send + Sync + 'static,
        FnUInput: Fn(),
    {
        for message in self.receiver.take().unwrap() {
            match message {
                Ok(message) => {
                    trace!("Received message: {message:?}");
                    match message {
                        MessageInbound::PointerEvent(event) => self.process_pointer_event(&event),
                        MessageInbound::WheelEvent(event) => self.process_wheel_event(&event),
                        MessageInbound::KeyboardEvent(event) => self.process_keyboard_event(&event),
                        MessageInbound::GetCapturableList => self.send_capturable_list(),
                        MessageInbound::Config(config) => self.update_config(config),
                        MessageInbound::PauseVideo => {
                            self.video_sender.send(VideoCommands::Pause).unwrap()
                        }
                        MessageInbound::ResumeVideo => {
                            self.video_sender.send(VideoCommands::Resume).unwrap()
                        }
                        MessageInbound::RestartVideo => {
                            self.video_sender.send(VideoCommands::Restart).unwrap()
                        }
                        MessageInbound::ChooseCustomInputAreas => {
                            let (sender, receiver) = std::sync::mpsc::channel();
                            crate::gui::get_input_area(self.config.no_gui, sender);
                            let mut sender = self.sender.clone();
                            spawn(move || {
                                while let Ok(areas) = receiver.recv() {
                                    send_message(
                                        &mut sender,
                                        MessageOutbound::CustomInputAreas(areas),
                                    );
                                }
                            });
                        }
                    }
                }
                Err(err) => {
                    warn!("Failed to read message {err}!");
                    self.send_message(MessageOutbound::Error(
                        "Failed to read message!".to_string(),
                    ));
                }
            }
        }

        drop(self.video_sender);
        if let Err(err) = self.video_thread.join() {
            warn!("Failed to join video thread: {err:?}");
        }
    }

    fn send_message(&mut self, message: MessageOutbound)
    where
        S: WeylusSender,
    {
        send_message(&mut self.sender, message)
    }

    fn process_wheel_event(&mut self, event: &WheelEvent) {
        match &mut self.input_device {
            Some(i) => i.send_wheel_event(event),
            None => warn!("Input device is not initalized, can not process WheelEvent!"),
        }
    }

    fn process_pointer_event(&mut self, event: &PointerEvent) {
        if self.input_device.is_some() {
            self.input_device
                .as_mut()
                .unwrap()
                .send_pointer_event(event)
        } else {
            warn!("Input device is not initalized, can not process PointerEvent!");
        }
    }

    fn process_keyboard_event(&mut self, event: &KeyboardEvent) {
        if self.input_device.is_some() {
            self.input_device
                .as_mut()
                .unwrap()
                .send_keyboard_event(event)
        } else {
            warn!("Input device is not initalized, can not process KeyboardEvent!");
        }
    }

    fn send_capturable_list(&mut self)
    where
        S: WeylusSender,
    {
        let mut windows = Vec::<String>::new();
        self.capturables = get_capturables(
            #[cfg(target_os = "linux")]
            self.config.wayland_support,
            #[cfg(target_os = "linux")]
            self.capture_cursor,
        );
        self.capturables.iter().for_each(|c| {
            windows.push(c.name());
        });
        self.send_message(MessageOutbound::CapturableList(windows));
    }

    fn update_config(&mut self, config: ClientConfiguration)
    where
        S: WeylusSender,
        FnUInput: Fn(),
    {
        let client_name_changed = if self.client_name != config.client_name {
            self.client_name = config.client_name;
            true
        } else {
            false
        };
        #[cfg(target_os = "linux")]
        let virtual_capturable: Option<Box<dyn Capturable>> =
            config.virtual_display.as_ref().map(|v| {
                // Fit within 4K while keeping the requested shape, with even dimensions.
                let (w, h) = (v.width.max(320) as f64, v.height.max(240) as f64);
                let fit = (3840.0 / w).min(2160.0 / h).min(1.0);
                let even = |x: f64| ((x * fit) as u32 / 2 * 2).max(2);
                Box::new(crate::capturable::mutter_virtual::VirtualDisplayCapturable {
                    width: even(w),
                    height: even(h),
                }) as Box<dyn Capturable>
            });
        #[cfg(not(target_os = "linux"))]
        let virtual_capturable: Option<Box<dyn Capturable>> = None;

        if virtual_capturable.is_some() || config.capturable_id < self.capturables.len() {
            let capturable = virtual_capturable
                .unwrap_or_else(|| self.capturables[config.capturable_id].clone());

            #[cfg(target_os = "linux")]
            {
                self.capture_cursor = config.capture_cursor;
            }

            #[cfg(target_os = "linux")]
            if config.uinput_support {
                if self.input_device.as_ref().map_or(true, |d| {
                    client_name_changed || d.device_type() != InputDeviceType::UInputDevice
                }) {
                    let device = crate::input::uinput_device::UInputDevice::new(
                        capturable.clone(),
                        &self.client_name,
                    );
                    match device {
                        Ok(d) => self.input_device = Some(Box::new(d)),
                        Err(e) => {
                            error!("Failed to create uinput device: {}", e);
                            if let CErrorCode::UInputNotAccessible = e.to_enum() {
                                (self.on_uinput_inaccessible)();
                            }
                            self.send_message(MessageOutbound::ConfigError(
                                "Failed to create uinput device!".to_string(),
                            ));
                            return;
                        }
                    }
                } else if let Some(d) = self.input_device.as_mut() {
                    d.set_capturable(capturable.clone());
                }
            } else if self.input_device.as_ref().map_or(true, |d| {
                d.device_type() != InputDeviceType::AutoPilotDevice
            }) {
                self.input_device = Some(Box::new(
                    crate::input::autopilot_device::AutoPilotDevice::new(capturable.clone()),
                ));
            } else if let Some(d) = self.input_device.as_mut() {
                d.set_capturable(capturable.clone());
            }

            #[cfg(target_os = "macos")]
            if self.input_device.is_none() {
                self.input_device = Some(Box::new(
                    crate::input::autopilot_device::AutoPilotDevice::new(capturable.clone()),
                ));
            } else {
                self.input_device
                    .as_mut()
                    .map(|d| d.set_capturable(capturable.clone()));
            }
            #[cfg(target_os = "windows")]
            if self.input_device.is_none() {
                self.input_device = Some(Box::new(
                    crate::input::autopilot_device_win::WindowsInput::new(capturable.clone()),
                ));
            } else {
                self.input_device
                    .as_mut()
                    .map(|d| d.set_capturable(capturable.clone()));
            }

            self.video_sender
                .send(VideoCommands::Start(VideoConfig {
                    capturable,
                    capture_cursor: config.capture_cursor,
                    max_width: config.max_width,
                    max_height: config.max_height,
                    frame_rate: config.frame_rate,
                    keyframe_interval: config.keyframe_interval.unwrap_or(0),
                    quality_qp: config.quality_qp.map_or(0, |q| q.clamp(1, 51)),
                }))
                .unwrap();
        } else {
            error!("Got invalid id for capturable: {}", config.capturable_id);
            self.send_message(MessageOutbound::ConfigError(
                "Invalid id for capturable!".to_string(),
            ));
        }
    }
}

fn handle_video<S: WeylusSender + Clone + 'static>(
    receiver: mpsc::Receiver<VideoCommands>,
    mut sender: S,
    encoder_options: EncoderOptions,
) {
    const EFFECTIVE_INIFINITY: Duration = Duration::from_secs(3600 * 24 * 365 * 200);

    let mut recorder: Option<Box<dyn Recorder>> = None;
    let mut video_encoder: Option<Box<VideoEncoder>> = None;

    let mut max_width = 1920;
    let mut max_height = 1080;
    let mut keyframe_interval = 0u32;
    // name and cursor setting of what's being recorded
    let mut current_capture: Option<(String, bool)> = None;

    // WEYLUS_STATS=1: log frame pacing every 2 s to diagnose stutter
    let stats_enabled = std::env::var_os("WEYLUS_STATS").is_some();
    let bytes_sent = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    let mut stats_start = Instant::now();
    let (mut st_ticks, mut st_new, mut st_encoded) = (0u32, 0u32, 0u32);
    let mut st_encode_time = Duration::ZERO;
    let mut st_max_encode = Duration::ZERO;
    let mut st_last_encode = Instant::now();
    let mut st_max_gap = Duration::ZERO;
    let mut quality_qp = 0u32;
    let mut frame_duration = EFFECTIVE_INIFINITY;
    let mut last_frame = Instant::now();
    let mut paused = false;

    loop {
        let now = Instant::now();
        let elapsed = now - last_frame;
        let frames_passed = (elapsed.as_secs_f64() / frame_duration.as_secs_f64()) as u32;
        let next_frame = last_frame + (frames_passed + 1) * frame_duration;
        let timeout = next_frame - now;
        last_frame = next_frame;

        if frames_passed > 0 {
            trace!("Dropped {frames_passed} frame(s)!");
        }

        match receiver.recv_timeout(if paused { EFFECTIVE_INIFINITY } else { timeout }) {
            Ok(VideoCommands::Start(config)) => {
                // Re-sending the same config (e.g. after changing quality settings) must not tear
                // down and recreate a virtual display: that would bounce every window on it.
                let same_virtual_display = recorder.is_some()
                    && config.capturable.name().starts_with("Virtual display")
                    && current_capture == Some((config.capturable.name(), config.capture_cursor));
                if same_virtual_display {
                    max_width = config.max_width;
                    max_height = config.max_height;
                    if keyframe_interval != config.keyframe_interval
                        || quality_qp != config.quality_qp
                    {
                        video_encoder = None;
                    }
                    keyframe_interval = config.keyframe_interval;
                    quality_qp = config.quality_qp;
                    let d = 1.0 / config.frame_rate;
                    frame_duration = if d.is_finite() {
                        Duration::from_secs_f64(d).min(EFFECTIVE_INIFINITY)
                    } else {
                        EFFECTIVE_INIFINITY
                    };
                    send_message(&mut sender, MessageOutbound::ConfigOk);
                    continue;
                }
                current_capture = Some((config.capturable.name(), config.capture_cursor));
                #[allow(unused_assignments)]
                {
                    // gstpipewire can not handle setting a pipeline's state to Null after another
                    // pipeline has been created and its state has been set to Play.
                    // This line makes sure that there always is only a single recorder and thus
                    // single pipeline in this thread by forcing rust to call the destructor of the
                    // current pipeline here, right before creating a new pipeline.
                    // See: https://gitlab.freedesktop.org/pipewire/pipewire/-/issues/986
                    //
                    // This shouldn't affect other Recorder trait objects.
                    recorder = None;
                }
                match config.capturable.recorder(config.capture_cursor) {
                    Ok(r) => {
                        recorder = Some(r);
                        max_width = config.max_width;
                        max_height = config.max_height;
                        if keyframe_interval != config.keyframe_interval
                            || quality_qp != config.quality_qp
                        {
                            // encoder settings changed: make the next frame start a new stream
                            video_encoder = None;
                        }
                        keyframe_interval = config.keyframe_interval;
                        quality_qp = config.quality_qp;
                        send_message(&mut sender, MessageOutbound::ConfigOk);
                    }
                    Err(err) => {
                        warn!("Failed to init screen cast: {}!", err);
                        send_message(
                            &mut sender,
                            MessageOutbound::Error("Failed to init screen cast!".into()),
                        )
                    }
                }
                last_frame = Instant::now();

                // The Duration type can not handle infinity, if the frame rate is set to 0 we just
                // set the duration between two frames to a very long one, which is effectively
                // infinity.
                let d = 1.0 / config.frame_rate;
                frame_duration = if d.is_finite() {
                    Duration::from_secs_f64(d)
                } else {
                    EFFECTIVE_INIFINITY
                };
                frame_duration = frame_duration.min(EFFECTIVE_INIFINITY);
            }
            Ok(VideoCommands::Pause) => {
                paused = true;
            }
            Ok(VideoCommands::Resume) => {
                paused = false;
            }
            Ok(VideoCommands::Restart) => {
                video_encoder = None;
            }
            Err(RecvTimeoutError::Timeout) => {
                if recorder.is_none() {
                    warn!("Screen capture not initalized, can not send video frame!");
                    continue;
                }
                // Nothing changed on screen and the decoder already has this picture: skip
                // encoding entirely. (A missing encoder means a new stream that needs a frame.)
                let is_new = recorder.as_mut().unwrap().poll_new_frame();
                if stats_enabled {
                    st_ticks += 1;
                    if is_new {
                        st_new += 1;
                    }
                    if stats_start.elapsed() >= Duration::from_secs(2) {
                        let secs = stats_start.elapsed().as_secs_f64();
                        info!(
                            "stats: {:.1} ticks/s, {:.1} arrived/s, {:.1} new frames/s from compositor, {:.1} encoded/s, \
                            encode avg {:.1} ms max {:.1} ms, longest gap between encodes {:.0} ms, {:.2} Mbit/s",
                            st_ticks as f64 / secs,
                            {
                                #[cfg(target_os = "linux")]
                                let arrived = crate::capturable::pipewire::SAMPLES_ARRIVED
                                    .swap(0, std::sync::atomic::Ordering::Relaxed);
                                #[cfg(not(target_os = "linux"))]
                                let arrived = 0u32;
                                arrived as f64 / secs
                            },
                            st_new as f64 / secs,
                            st_encoded as f64 / secs,
                            if st_encoded > 0 { st_encode_time.as_secs_f64() * 1000.0 / st_encoded as f64 } else { 0.0 },
                            st_max_encode.as_secs_f64() * 1000.0,
                            st_max_gap.as_secs_f64() * 1000.0,
                            bytes_sent.swap(0, std::sync::atomic::Ordering::Relaxed) as f64 * 8.0 / 1e6 / secs,
                        );
                        stats_start = Instant::now();
                        (st_ticks, st_new, st_encoded) = (0, 0, 0);
                        st_encode_time = Duration::ZERO;
                        st_max_encode = Duration::ZERO;
                        st_max_gap = Duration::ZERO;
                    }
                }
                if !is_new && video_encoder.is_some() {
                    continue;
                }
                let pixel_data = recorder.as_mut().unwrap().capture();
                if let Err(err) = pixel_data {
                    warn!("Error capturing screen: {}", err);
                    continue;
                }
                let pixel_data = pixel_data.unwrap();
                let (width_in, height_in) = pixel_data.size();
                let scale =
                    (max_width as f64 / width_in as f64).min(max_height as f64 / height_in as f64);
                // limit video to 4K
                let scale_max = (3840.0 / width_in as f64).min(2160.0 / height_in as f64);
                let scale = scale.min(scale_max);
                let mut width_out = width_in;
                let mut height_out = height_in;
                if scale < 1.0 {
                    width_out = (width_out as f64 * scale) as usize;
                    height_out = (height_out as f64 * scale) as usize;
                }
                // video encoder is not setup or setup for encoding the wrong size: restart it
                if video_encoder.is_none()
                    || !video_encoder
                        .as_ref()
                        .unwrap()
                        .check_size(width_in, height_in, width_out, height_out)
                {
                    send_message(&mut sender, MessageOutbound::NewVideo);
                    let mut sender = sender.clone();
                    let bytes_sent = bytes_sent.clone();
                    let res = VideoEncoder::new(
                        width_in,
                        height_in,
                        width_out,
                        height_out,
                        move |data| {
                            bytes_sent.fetch_add(
                                data.len() as u64,
                                std::sync::atomic::Ordering::Relaxed,
                            );
                            if let Err(err) = sender.send_video(data) {
                                warn!("Failed to send video frame: {err}!");
                            }
                        },
                        encoder_options,
                        keyframe_interval,
                        quality_qp,
                    );
                    match res {
                        Ok(r) => video_encoder = Some(r),
                        Err(e) => {
                            warn!("{}", e);
                            continue;
                        }
                    };
                }
                let video_encoder = video_encoder.as_mut().unwrap();
                let t = Instant::now();
                let filled = video_encoder.fill(pixel_data);
                // the GPU is done with the captured buffer: give it back before encoding
                recorder.as_mut().unwrap().release_frame();
                if filled {
                    video_encoder.encode_filled();
                }
                if stats_enabled {
                    let took = t.elapsed();
                    st_encoded += 1;
                    st_encode_time += took;
                    st_max_encode = st_max_encode.max(took);
                    st_max_gap = st_max_gap.max(st_last_encode.elapsed());
                    st_last_encode = Instant::now();
                }
            }
            // stop thread once the channel is closed
            Err(RecvTimeoutError::Disconnected) => return,
        };
    }
}

pub struct WsWeylusReceiver {
    recv: tokio::sync::mpsc::Receiver<MessageInbound>,
}

impl Iterator for WsWeylusReceiver {
    type Item = Result<MessageInbound, Infallible>;

    fn next(&mut self) -> Option<Self::Item> {
        self.recv.blocking_recv().map(Ok)
    }
}

impl WeylusReceiver for WsWeylusReceiver {
    type Error = Infallible;
}

pub enum WsMessage {
    Frame(Frame<'static>),
    Video(Vec<u8>),
    MessageOutbound(MessageOutbound),
}

unsafe impl Send for WsMessage {}

#[derive(Clone)]
pub struct WsWeylusSender {
    sender: tokio::sync::mpsc::Sender<WsMessage>,
}

impl WeylusSender for WsWeylusSender {
    type Error = tokio::sync::mpsc::error::SendError<WsMessage>;

    fn send_message(&mut self, message: MessageOutbound) -> Result<(), Self::Error> {
        self.sender
            .blocking_send(WsMessage::MessageOutbound(message))
    }

    fn send_video(&mut self, bytes: &[u8]) -> Result<(), Self::Error> {
        self.sender.blocking_send(WsMessage::Video(bytes.to_vec()))
    }
}

pub fn weylus_websocket_channel(
    websocket: WebSocket<TokioIo<Upgraded>>,
    semaphore_shutdown: Arc<tokio::sync::Semaphore>,
) -> (WsWeylusSender, WsWeylusReceiver) {
    let (rx, mut tx) = websocket.split(|ws| tokio::io::split(ws));

    let mut rx = FragmentCollectorRead::new(rx);

    let (sender_inbound, receiver_inbound) = channel::<MessageInbound>(32);
    let (sender_outbound, mut receiver_outbound) = channel::<WsMessage>(32);

    {
        let sender_outbound = sender_outbound.clone();
        tokio::spawn(async move {
            let mut send_fn = |frame| async {
                if let Err(err) = sender_outbound.send(WsMessage::Frame(frame)).await {
                    warn!("Failed to send websocket frame while receiving fragmented frame: {err}.")
                };
                Ok(())
            };

            loop {
                let fut = rx.read_frame::<_, WebSocketError>(&mut send_fn);

                let frame = tokio::select! {
                    _ = semaphore_shutdown.acquire() => break,
                    frame = fut => match frame {
                        Ok(frame) => frame,
                        Err(err) => {
                            warn!("Invalid websocket frame: {err}.");
                            break;
                        },
                    },
                };
                match frame.opcode {
                    OpCode::Close => break,
                    OpCode::Text => match serde_json::from_slice(&frame.payload) {
                        Ok(msg) => {
                            if let Err(err) = sender_inbound.send(msg).await {
                                warn!("Failed to forward inbound message to WeylusClientHandler: {err}.");
                            }
                        }
                        Err(err) => warn!("Failed to parse message: {err}"),
                    },
                    _ => {}
                }
            }
        });
    }

    tokio::spawn(async move {
        loop {
            let msg = if let Some(msg) = receiver_outbound.recv().await {
                msg
            } else {
                break;
            };

            match msg {
                WsMessage::Frame(frame) => {
                    if let Err(err) = tx.write_frame(frame).await {
                        if let WebSocketError::ConnectionClosed = err {
                            break;
                        }
                        warn!("Failed to send frame: {err}");
                    }
                }
                WsMessage::Video(data) => {
                    if let Err(err) = tx.write_frame(Frame::binary(data.into())).await {
                        if let WebSocketError::ConnectionClosed = err {
                            break;
                        }
                        warn!("Failed to send video frame: {err}");
                    }
                }
                WsMessage::MessageOutbound(msg) => {
                    let json_string = serde_json::to_string(&msg).unwrap();
                    let data = json_string.as_bytes();
                    if let Err(err) = tx.write_frame(Frame::text(data.into())).await {
                        if let WebSocketError::ConnectionClosed = err {
                            break;
                        }
                        warn!("Failed to send outbound message: {err}");
                    }
                }
            }
        }
    });

    (
        WsWeylusSender {
            sender: sender_outbound,
        },
        WsWeylusReceiver {
            recv: receiver_inbound,
        },
    )
}
