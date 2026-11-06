// Disable the console window that pops up when you launch the .exe
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg(not(windows))]
compile_error!("Flux is a Windows screensaver: build it for a Windows target (see README).");

mod preferences;
mod screensaver;
mod settings_window;

use screensaver::{Mode, MouseExit};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// How long to pause a display that is hidden, minimized or has no size.
const IDLE_RETRY: Duration = Duration::from_millis(100);
/// How often to check again while Windows reports the display as off.
const DISPLAY_OFF_RETRY: Duration = Duration::from_millis(500);

use winit::{
    application::ApplicationHandler,
    event::{ElementState, KeyEvent, WindowEvent},
    event_loop::{ActiveEventLoop, EventLoop},
    keyboard::{KeyCode, PhysicalKey},
    monitor::MonitorHandle,
    window::{Window, WindowId, WindowLevel},
};

use flux::{Flux, Settings, display_size::DisplaySize};

struct App {
    flux: Flux,
    _settings: Arc<Settings>,
}

struct GpuState {
    device: wgpu::Device,
    command_queue: wgpu::Queue,
    window_surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
    size: Option<DisplaySize>,
    resize_pending: bool,
    scale_factor: f64,
}

impl GpuState {
    fn resize_before_draw(&mut self, window: &Window, flux: &mut Flux) {
        if !self.resize_pending {
            return;
        }
        self.resize_pending = false;
        // ScaleFactorChanged can precede the OS's final Resized event. Read
        // the current physical dimensions after both events, before drawing.
        let physical = window.inner_size();
        let next = DisplaySize::from_physical(
            physical.width,
            physical.height,
            self.scale_factor,
            self.device.limits().max_texture_dimension_2d,
        );
        if self.size == next {
            return;
        }
        if let Some(size) = next {
            if self.size.is_none()
                || self.config.width != size.physical_width
                || self.config.height != size.physical_height
            {
                self.config.width = size.physical_width;
                self.config.height = size.physical_height;
                self.window_surface.configure(&self.device, &self.config);
            }
            flux.resize(
                &self.device,
                &self.command_queue,
                size.logical_width,
                size.logical_height,
                size.physical_width,
                size.physical_height,
            );
        }
        self.size = next;
    }
}

/// GPU objects shared by every display: one instance, adapter, device and
/// queue. Each display only adds its own surface and simulation.
#[derive(Clone)]
struct SharedGpu {
    instance: wgpu::Instance,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    caps: flux::BackendCaps,
}

impl SharedGpu {
    /// Create the shared GPU for the first window, plus that window's surface.
    fn new(
        window: &Arc<Window>,
        power_preference: wgpu::PowerPreference,
    ) -> Result<(Self, wgpu::Surface<'static>), String> {
        // Only the backends compiled in are used: Direct3D 12 on Windows.
        let instance =
            wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle().with_env());
        let no_gpu = || "Er is geen videokaart met DirectX 12-ondersteuning gevonden.".to_string();
        let surface = instance
            .create_surface(window.clone())
            .map_err(|error| format!("{} ({error})", no_gpu()))?;
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference,
            force_fallback_adapter: false,
            compatible_surface: Some(&surface),
            apply_limit_buckets: false,
        }))
        .map_err(|_| no_gpu())?;
        log::info!("Adapter ({power_preference:?}): {:?}", adapter.get_info());

        let caps = flux::BackendCaps {
            float32_filterable: adapter
                .features()
                .contains(wgpu::Features::FLOAT32_FILTERABLE),
        };
        log::info!("Backend caps: {:?}", caps);

        let mut features = wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES;
        if caps.float32_filterable {
            features |= wgpu::Features::FLOAT32_FILTERABLE;
        }
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: None,
            required_features: features,
            required_limits: wgpu::Limits::default().using_resolution(adapter.limits()),
            memory_hints: wgpu::MemoryHints::Performance,
            trace: wgpu::Trace::Off,
            experimental_features: wgpu::ExperimentalFeatures::disabled(),
        }))
        .map_err(|error| format!("De videokaart kon niet worden gestart: {error}"))?;

        let gpu = Self {
            instance,
            adapter,
            device,
            queue,
            caps,
        };
        Ok((gpu, surface))
    }

    /// A surface for another display on the already chosen adapter.
    fn surface_for(&self, window: &Arc<Window>) -> Result<wgpu::Surface<'static>, String> {
        let surface = self
            .instance
            .create_surface(window.clone())
            .map_err(|error| format!("Dit beeldscherm kan niet worden gebruikt: {error}"))?;
        if !self.adapter.is_surface_supported(&surface) {
            return Err(
                "Dit beeldscherm wordt niet ondersteund door de gekozen videokaart.".into(),
            );
        }
        Ok(surface)
    }
}

struct FluxApp {
    mode: Mode,
    monitor: Option<MonitorHandle>,
    preferences: preferences::Preferences,
    mouse_exit: MouseExit,
    window: Option<Arc<Window>>,
    gpu: Option<GpuState>,
    app: Option<App>,
    start: Instant,
    first_frame: Option<Instant>,
    /// Earliest moment this display should draw its next frame.
    next_frame: Instant,
    /// Minimum time between frames, or None to follow vsync.
    frame_interval: Option<Duration>,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut logger =
        env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"));
    // Next to settings.json: always writable, unlike System32 or Program Files.
    if let Ok(path) = preferences::path().map(|path| path.with_file_name("Flux.log")) {
        let file = path
            .parent()
            .map_or(Ok(()), std::fs::create_dir_all)
            .and_then(|()| std::fs::File::create(&path));
        if let Ok(file) = file {
            logger.target(env_logger::Target::Pipe(Box::new(file)));
        }
    }
    logger.init();
    std::panic::set_hook(Box::new(|info| log::error!("Fatal error: {info}")));

    let is_scr = std::env::current_exe()?
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("scr"));
    let mode = match Mode::parse(&std::env::args().skip(1).collect::<Vec<_>>(), is_scr) {
        Ok(mode) => mode,
        Err(message) => {
            screensaver::show_message(message);
            return Ok(());
        }
    };
    match mode {
        Mode::Configure => {
            if let Err(error) = settings_window::run() {
                screensaver::show_message(&error);
            }
            return Ok(());
        }
        Mode::Preview(handle) if screensaver::preview_size(handle).is_none() => {
            log::warn!("Preview host is unavailable or unsupported on this platform");
            return Ok(());
        }
        _ => {}
    }

    let event_loop = EventLoop::new().unwrap();
    event_loop.set_control_flow(winit::event_loop::ControlFlow::Poll);
    let mut flux_app = MultiMonitorApp {
        mode,
        displays: Vec::new(),
        gpu: None,
        _display_power: screensaver::DisplayPowerWatch::start(),
    };
    event_loop.run_app(&mut flux_app)?;
    Ok(())
}

// One event loop owns every display, so any exit request closes the entire saver.
struct MultiMonitorApp {
    mode: Mode,
    displays: Vec<FluxApp>,
    gpu: Option<SharedGpu>,
    _display_power: Option<screensaver::DisplayPowerWatch>,
}

impl ApplicationHandler for MultiMonitorApp {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if !self.displays.is_empty() {
            return;
        }
        let monitors = if self.mode == Mode::Saver {
            let monitors: Vec<_> = event_loop.available_monitors().map(Some).collect();
            if monitors.is_empty() {
                vec![event_loop.primary_monitor()]
            } else {
                monitors
            }
        } else {
            vec![None]
        };
        log::info!("Starting {:?} on {} display(s)", self.mode, monitors.len());
        let mut preferences = preferences::load();
        log::info!("Loaded preferences: {preferences:?}");
        if matches!(self.mode, Mode::Preview(_)) {
            // The preview pane is tiny: low quality at 30 fps looks the same.
            preferences.quality = "Low".into();
            preferences.frame_limit = 30;
            log::info!("Preview uses low quality at 30 fps");
        }
        for monitor in monitors {
            if let Some(monitor) = &monitor {
                log::info!(
                    "Display {:?}: position={:?}, size={:?}, scale={}",
                    monitor.name(),
                    monitor.position(),
                    monitor.size(),
                    monitor.scale_factor()
                );
            }
            let mut display = FluxApp {
                mode: self.mode,
                monitor,
                preferences: preferences.clone(),
                mouse_exit: MouseExit::default(),
                window: None,
                gpu: None,
                app: None,
                start: Instant::now(),
                first_frame: None,
                next_frame: Instant::now(),
                frame_interval: None,
            };
            display.start(event_loop, &mut self.gpu);
            self.displays.push(display);
            if event_loop.exiting() {
                // A display failed to start; hide the ones already shown.
                for window in self
                    .displays
                    .iter()
                    .filter_map(|display| display.window.as_ref())
                {
                    window.set_visible(false);
                }
                return;
            }
        }
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        window_id: WindowId,
        event: WindowEvent,
    ) {
        // Render all displays as a batch in about_to_wait; Windows paint events
        // can otherwise continuously favor the active window.
        if matches!(event, WindowEvent::RedrawRequested) {
            return;
        }
        if let Some(display) = self.displays.iter_mut().find(|display| {
            display
                .window
                .as_ref()
                .is_some_and(|window| window.id() == window_id)
        }) {
            display.window_event(event_loop, window_id, event);
        }
        if event_loop.exiting() {
            // Reveal the desktop at once; GPU teardown can take a moment,
            // especially on a busy integrated GPU.
            for window in self
                .displays
                .iter()
                .filter_map(|display| display.window.as_ref())
            {
                window.set_visible(false);
            }
        }
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        // Draw every display that is due, then sleep until the earliest next
        // frame. Without a frame limit displays are always due and vsync paces them.
        let now = Instant::now();
        let mut wake = now + IDLE_RETRY;
        for display in &mut self.displays {
            if let Mode::Preview(handle) = display.mode {
                let Some(size) = screensaver::preview_size(handle) else {
                    log::info!("Preview host closed; exiting");
                    event_loop.exit();
                    return;
                };
                if let Some(window) = &display.window {
                    if window.inner_size() != size {
                        let _ = window.request_inner_size(size);
                    }
                }
                if size.width == 0 || size.height == 0 {
                    continue;
                }
            }
            if event_loop.exiting() {
                return;
            }
            let Some(id) = display.window.as_ref().map(|window| window.id()) else {
                continue;
            };
            if screensaver::display_off() {
                // Nobody can see the animation; input still wakes the loop.
                display.next_frame = now + DISPLAY_OFF_RETRY;
            }
            if display.next_frame <= now {
                display.window_event(event_loop, id, WindowEvent::RedrawRequested);
            }
            wake = wake.min(display.next_frame);
        }
        event_loop.set_control_flow(if wake <= Instant::now() {
            winit::event_loop::ControlFlow::Poll
        } else {
            winit::event_loop::ControlFlow::WaitUntil(wake)
        });
    }
}
impl FluxApp {
    /// Stop cleanly when the GPU cannot be used instead of aborting.
    /// Only the windowed app shows a dialog: an unattended screensaver or a
    /// preview pane should not leave message boxes behind.
    fn gpu_failed(&self, event_loop: &ActiveEventLoop, window: &Window, message: &str) {
        log::error!("{message}");
        window.set_visible(false);
        if self.mode == Mode::Desktop {
            screensaver::show_message(message);
        }
        event_loop.exit();
    }

    /// Create this display's window and renderer on the shared GPU, creating
    /// that GPU first if this is the first display.
    fn start(&mut self, event_loop: &ActiveEventLoop, shared: &mut Option<SharedGpu>) {
        if self.window.is_some() {
            return;
        }

        let logical_size = winit::dpi::LogicalSize::new(1280, 800);

        let window_attributes = Window::default_attributes()
            .with_title("Flux")
            .with_visible(false)
            .with_decorations(true)
            .with_resizable(true)
            .with_inner_size(logical_size);

        let window_attributes = if self.mode == Mode::Saver {
            // Explicit borderless bounds keep all displays visible independently of focus.
            let attributes = window_attributes
                .with_decorations(false)
                .with_resizable(false)
                .with_window_level(WindowLevel::AlwaysOnTop);
            if let Some(monitor) = &self.monitor {
                attributes
                    .with_position(monitor.position())
                    .with_inner_size(monitor.size())
            } else {
                attributes
            }
        } else {
            window_attributes
        };
        let window_attributes = if let Mode::Preview(handle) = self.mode {
            let Some(size) = screensaver::preview_size(handle) else {
                event_loop.exit();
                return;
            };
            let parent = raw_window_handle::Win32WindowHandle::new(
                std::num::NonZeroIsize::new(handle as isize).unwrap(),
            );
            // The host HWND was validated above; its lifetime is checked before every frame.
            unsafe { window_attributes.with_parent_window(Some(parent.into())) }
                .with_decorations(false)
                .with_resizable(false)
                .with_active(false)
                .with_position(winit::dpi::PhysicalPosition::new(0, 0))
                .with_inner_size(size)
        } else {
            window_attributes
        };
        let window = Arc::new(event_loop.create_window(window_attributes).unwrap());
        if self.mode == Mode::Saver {
            window.set_cursor_visible(false);
        }

        self.frame_interval = frame_interval(
            self.preferences.frame_limit,
            window
                .current_monitor()
                .and_then(|monitor| monitor.refresh_rate_millihertz()),
        );
        log::info!("Frame interval: {:?}", self.frame_interval);

        let (window_surface, gpu) = match shared {
            Some(gpu) => match gpu.surface_for(&window) {
                Ok(surface) => (surface, gpu.clone()),
                Err(message) => return self.gpu_failed(event_loop, &window, &message),
            },
            None => match SharedGpu::new(&window, self.preferences.power_preference()) {
                Ok((gpu, surface)) => {
                    *shared = Some(gpu.clone());
                    (surface, gpu)
                }
                Err(message) => return self.gpu_failed(event_loop, &window, &message),
            },
        };
        let SharedGpu {
            adapter,
            device,
            queue: command_queue,
            caps,
            ..
        } = gpu;

        let swapchain_capabilities = window_surface.get_capabilities(&adapter);
        let Some(surface_output) = get_preferred_surface_output(&swapchain_capabilities) else {
            return self.gpu_failed(
                event_loop,
                &window,
                "Het beeldscherm ondersteunt geen geschikt kleurformaat voor Flux.",
            );
        };
        let display_hdr_info = window_surface.display_hdr_info(&adapter);
        log::info!(
            "Surface output: format={:?}, color_space={:?}, hdr={}, headroom={:?}",
            surface_output.format,
            surface_output.color_space,
            surface_output.color_space.is_hdr(),
            display_hdr_info.tone_map_headroom(),
        );
        log::debug!(
            "Surface format capabilities: {:?}",
            swapchain_capabilities.format_capabilities
        );

        let physical_size = window.inner_size();
        let scale_factor = render_scale(self.mode, &window, window.scale_factor());
        let size = DisplaySize::from_physical(
            physical_size.width,
            physical_size.height,
            scale_factor,
            device.limits().max_texture_dimension_2d,
        );
        let initial_size = size.unwrap_or(DisplaySize::from_logical(1, 1, 1.0, 1).unwrap());
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: surface_output.format,
            width: initial_size.physical_width,
            height: initial_size.physical_height,
            present_mode: wgpu::PresentMode::AutoVsync,
            // One queued frame keeps input (and exit) responsive on slow GPUs.
            desired_maximum_frame_latency: 1,
            alpha_mode: swapchain_capabilities.alpha_modes[0],
            view_formats: vec![],
            color_space: surface_output.color_space,
        };

        if size.is_some() {
            window_surface.configure(&device, &config);
        }
        let mut renderer_settings = self.preferences.renderer_settings();
        if matches!(self.mode, Mode::Preview(_)) {
            // Scaled down, normal lines would be under a pixel wide and faint.
            renderer_settings.line_width *= PREVIEW_LINE_WIDTH_BOOST;
        }
        let settings = Arc::new(renderer_settings);
        let flux = Flux::new(
            &device,
            &command_queue,
            surface_output.format,
            initial_size.logical_width,
            initial_size.logical_height,
            initial_size.physical_width,
            initial_size.physical_height,
            caps,
            &Arc::clone(&settings),
        );
        let flux = match flux {
            Ok(flux) => flux,
            Err(error) => {
                return self.gpu_failed(
                    event_loop,
                    &window,
                    &format!("De animatie kon niet worden gestart: {error}"),
                );
            }
        };

        self.app = Some(App {
            flux,
            _settings: settings,
        });

        self.gpu = Some(GpuState {
            device,
            command_queue,
            window_surface,
            config,
            size,
            resize_pending: false,
            scale_factor,
        });

        window.set_visible(true);
        window.request_redraw();
        log::info!(
            "Window {:?}: position={:?}, size={:?}",
            window.id(),
            window.outer_position(),
            window.inner_size()
        );
        self.window = Some(window);
        self.start = Instant::now();
        self.next_frame = self.start;
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        window_id: WindowId,
        event: WindowEvent,
    ) {
        let (Some(window), Some(gpu), Some(app)) =
            (self.window.as_ref(), self.gpu.as_mut(), self.app.as_mut())
        else {
            return;
        };

        if window_id != window.id() {
            return;
        }

        if self.mode == Mode::Saver {
            let armed = screensaver::input_armed(self.first_frame.map(|frame| frame.elapsed()));
            let exit = match &event {
                WindowEvent::KeyboardInput {
                    event,
                    is_synthetic: false,
                    ..
                } => armed && !event.repeat && event.state == ElementState::Pressed,
                WindowEvent::MouseInput {
                    state: ElementState::Pressed,
                    ..
                }
                | WindowEvent::MouseWheel { .. } => armed,
                WindowEvent::CursorMoved { position, .. } => self.mouse_exit.moved(
                    self.first_frame
                        .map(|frame| frame.elapsed())
                        .unwrap_or_default(),
                    position.x / window.scale_factor(),
                    position.y / window.scale_factor(),
                ),

                _ => false,
            };
            if exit {
                log::info!("Screensaver exit requested by input: {event:?}");
                event_loop.exit();
                return;
            }
        }

        match event {
            WindowEvent::CloseRequested | WindowEvent::Destroyed => event_loop.exit(),
            WindowEvent::KeyboardInput {
                event:
                    KeyEvent {
                        physical_key: PhysicalKey::Code(KeyCode::Escape),
                        state: ElementState::Released,
                        ..
                    },
                ..
            } if self.mode == Mode::Desktop => event_loop.exit(),
            WindowEvent::Resized(_) => {
                gpu.resize_pending = true;
                gpu.scale_factor = render_scale(self.mode, window, window.scale_factor());
                self.next_frame = Instant::now();
            }
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                gpu.resize_pending = true;
                gpu.scale_factor = render_scale(self.mode, window, scale_factor);
                self.next_frame = Instant::now();
            }
            WindowEvent::RedrawRequested => {
                let now = Instant::now();
                gpu.resize_before_draw(window, &mut app.flux);
                if gpu.size.is_none() {
                    self.next_frame = now + IDLE_RETRY;
                    return;
                }
                let frame = match gpu.window_surface.get_current_texture() {
                    wgpu::CurrentSurfaceTexture::Success(frame)
                    | wgpu::CurrentSurfaceTexture::Suboptimal(frame) => frame,
                    wgpu::CurrentSurfaceTexture::Timeout => {
                        self.next_frame = now;
                        return;
                    }
                    // Hidden or minimized: no vsync to wait on, so pause
                    // instead of spinning the CPU.
                    wgpu::CurrentSurfaceTexture::Occluded => {
                        self.next_frame = now + IDLE_RETRY;
                        return;
                    }
                    wgpu::CurrentSurfaceTexture::Outdated => {
                        gpu.window_surface.configure(&gpu.device, &gpu.config);
                        self.next_frame = now;
                        return;
                    }
                    status => panic!("Failed to acquire next swap chain texture: {status:?}"),
                };
                let view = frame
                    .texture
                    .create_view(&wgpu::TextureViewDescriptor::default());
                let mut encoder =
                    gpu.device
                        .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                            label: Some("flux:render"),
                        });

                app.flux.animate(
                    &gpu.device,
                    &gpu.command_queue,
                    &mut encoder,
                    &view,
                    None,
                    self.start.elapsed().as_secs_f64()
                        * 1000.0
                        * (self.preferences.speed as f64 / 100.0),
                );

                gpu.command_queue.submit(Some(encoder.finish()));
                window.pre_present_notify();
                gpu.command_queue.present(frame);
                self.next_frame = match self.frame_interval {
                    // Keep a steady cadence; restart it after falling behind.
                    Some(interval) => (self.next_frame + interval).max(now),
                    None => now,
                };
                if self.first_frame.is_none() {
                    self.first_frame = Some(Instant::now());
                    log::info!(
                        "First frame presented on {:?}; input exit arms in two seconds",
                        window.id()
                    );
                }
            }
            _ => (),
        }
    }
}

/// Logical height the preview pretends to have: the renderer's reference
/// screen height, so the preview shows a whole scene instead of a 1:1 crop.
const PREVIEW_LOGICAL_HEIGHT: f64 = 800.0;
/// Thicker lines in the preview so they stay visible when scaled down.
const PREVIEW_LINE_WIDTH_BOOST: f32 = 2.5;

/// Scale between physical pixels and the renderer's logical pixels.
///
/// The renderer shows a fixed-size world at 1:1 logical pixels, so the tiny
/// Windows preview pane (about 150×110) would only show a calm, nearly empty
/// crop of the centre. The preview renders a full-size scene scaled down.
fn render_scale(mode: Mode, window: &Window, os_scale: f64) -> f64 {
    match mode {
        Mode::Preview(_) => preview_scale(window.inner_size().height),
        _ => os_scale,
    }
}

fn preview_scale(physical_height: u32) -> f64 {
    f64::from(physical_height.max(1)) / PREVIEW_LOGICAL_HEIGHT
}

/// Time between frames for a frame limit, or None when vsync alone suffices.
fn frame_interval(limit: u32, refresh_millihertz: Option<u32>) -> Option<Duration> {
    if limit == 0 {
        return None;
    }
    // A display at or below the limit is already paced by vsync; an extra
    // timer would only add judder (5% tolerance for 59.94/60.05 Hz panels).
    if refresh_millihertz.is_some_and(|mhz| u64::from(mhz) * 100 <= u64::from(limit) * 105_000) {
        return None;
    }
    Some(Duration::from_secs_f64(1.0 / f64::from(limit)))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SurfaceOutput {
    format: wgpu::TextureFormat,
    color_space: wgpu::SurfaceColorSpace,
}

fn get_preferred_surface_output(capabilities: &wgpu::SurfaceCapabilities) -> Option<SurfaceOutput> {
    // Flux's existing output values are sRGB-encoded. Prefer an encoded
    // extended-sRGB surface where available (Metal and some Vulkan drivers),
    // preserving the current appearance and values above SDR white.
    let encoded_hdr = SurfaceOutput {
        format: wgpu::TextureFormat::Rgba16Float,
        color_space: wgpu::SurfaceColorSpace::ExtendedSrgb,
    };
    if supports_surface_output(capabilities, encoded_hdr) {
        return Some(encoded_hdr);
    }

    // Linear scRGB and PQ/HLG need an explicit output conversion pass. Until
    // Flux has one, using those spaces would alter the existing colors.
    // Preserve the existing SDR output convention: non-sRGB formats contain an
    // sRGB-encoded signal, while *Srgb formats perform the encoding on store.
    // Every candidate is paired with an explicitly advertised color space.
    let sdr_formats = [
        wgpu::TextureFormat::Rgb10a2Unorm,
        wgpu::TextureFormat::Bgra8Unorm,
        wgpu::TextureFormat::Rgba8Unorm,
        wgpu::TextureFormat::Bgra8UnormSrgb,
        wgpu::TextureFormat::Rgba8UnormSrgb,
    ];
    sdr_formats.into_iter().find_map(|format| {
        let output = SurfaceOutput {
            format,
            color_space: wgpu::SurfaceColorSpace::Srgb,
        };
        supports_surface_output(capabilities, output).then_some(output)
    })
}

fn supports_surface_output(
    capabilities: &wgpu::SurfaceCapabilities,
    output: SurfaceOutput,
) -> bool {
    capabilities
        .color_spaces(output.format)
        .contains(output.color_space.to_color_spaces().unwrap())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn capabilities(
        formats: &[(wgpu::TextureFormat, wgpu::SurfaceColorSpaces)],
    ) -> wgpu::SurfaceCapabilities {
        wgpu::SurfaceCapabilities {
            formats: Vec::new(),
            format_capabilities: formats
                .iter()
                .map(|&(format, color_spaces)| wgpu::SurfaceFormatCapabilities {
                    format,
                    color_spaces,
                })
                .collect(),
            present_modes: Vec::new(),
            alpha_modes: vec![wgpu::CompositeAlphaMode::Opaque],
            usages: wgpu::TextureUsages::RENDER_ATTACHMENT,
        }
    }

    #[test]
    fn preview_renders_a_reference_height_scene() {
        let size = DisplaySize::from_physical(152, 112, preview_scale(112), 8192).unwrap();
        assert_eq!(size.logical_height, 800);
        assert_eq!(size.logical_width, 1086);
        assert_eq!((size.physical_width, size.physical_height), (152, 112));
    }

    #[test]
    fn frame_limit_only_applies_above_the_display_refresh_rate() {
        assert_eq!(frame_interval(0, Some(144_000)), None);
        assert_eq!(frame_interval(60, Some(60_000)), None);
        assert_eq!(frame_interval(60, Some(59_940)), None);
        assert_eq!(
            frame_interval(60, Some(144_000)),
            Some(Duration::from_secs_f64(1.0 / 60.0))
        );
        assert_eq!(
            frame_interval(30, Some(60_000)),
            Some(Duration::from_secs_f64(1.0 / 30.0))
        );
        assert_eq!(
            frame_interval(60, None),
            Some(Duration::from_secs_f64(1.0 / 60.0))
        );
    }

    #[test]
    fn falls_back_to_sdr_when_only_linear_hdr_is_advertised() {
        let capabilities = capabilities(&[
            (
                wgpu::TextureFormat::Bgra8Unorm,
                wgpu::SurfaceColorSpaces::SRGB,
            ),
            (
                wgpu::TextureFormat::Rgba16Float,
                wgpu::SurfaceColorSpaces::EXTENDED_SRGB_LINEAR,
            ),
        ]);

        assert_eq!(
            get_preferred_surface_output(&capabilities),
            Some(SurfaceOutput {
                format: wgpu::TextureFormat::Bgra8Unorm,
                color_space: wgpu::SurfaceColorSpace::Srgb,
            })
        );
    }

    #[test]
    fn prefers_encoded_hdr_without_changing_existing_colors() {
        let capabilities = capabilities(&[
            (
                wgpu::TextureFormat::Rgba16Float,
                wgpu::SurfaceColorSpaces::EXTENDED_SRGB,
            ),
            (
                wgpu::TextureFormat::Bgra8Unorm,
                wgpu::SurfaceColorSpaces::SRGB,
            ),
        ]);

        assert_eq!(
            get_preferred_surface_output(&capabilities),
            Some(SurfaceOutput {
                format: wgpu::TextureFormat::Rgba16Float,
                color_space: wgpu::SurfaceColorSpace::ExtendedSrgb,
            })
        );
    }

    #[test]
    fn falls_back_to_supported_sdr_pair() {
        let capabilities = capabilities(&[
            (
                wgpu::TextureFormat::Rgb10a2Unorm,
                wgpu::SurfaceColorSpaces::BT2100_PQ,
            ),
            (
                wgpu::TextureFormat::Bgra8Unorm,
                wgpu::SurfaceColorSpaces::SRGB,
            ),
        ]);

        assert_eq!(
            get_preferred_surface_output(&capabilities),
            Some(SurfaceOutput {
                format: wgpu::TextureFormat::Bgra8Unorm,
                color_space: wgpu::SurfaceColorSpace::Srgb,
            })
        );
    }
}
