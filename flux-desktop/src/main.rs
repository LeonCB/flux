// Disable the console window that pops up when you launch the .exe
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod clock_overlay;
mod preferences;
mod screensaver;
use image::RgbaImage;
use screensaver::{Mode, MouseExit};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

use winit::{
    application::ApplicationHandler,
    event::{ElementState, KeyEvent, WindowEvent},
    event_loop::{ActiveEventLoop, EventLoop},
    keyboard::{KeyCode, PhysicalKey},
    monitor::MonitorHandle,
    window::{Window, WindowId, WindowLevel},
};

#[cfg(target_os = "macos")]
use winit::platform::macos::WindowAttributesExtMacOS;

use flux::{display_size::DisplaySize, Flux, Settings};

struct App {
    runtime: tokio::runtime::Runtime,
    tx: mpsc::Sender<Msg>,
    rx: mpsc::Receiver<Msg>,

    flux: Flux,
    _settings: Arc<Settings>,

    color_image: Arc<Mutex<Option<RgbaImage>>>,
}

enum Msg {
    DecodedImage,
}

impl App {
    fn handle_pending_messages(&mut self, device: &wgpu::Device, queue: &wgpu::Queue) {
        while let Ok(msg) = self.rx.try_recv() {
            match msg {
                Msg::DecodedImage => {
                    if let Some(image) = &*self.color_image.lock().unwrap() {
                        self.flux.sample_colors_from_image(device, queue, image);
                    }
                }
            }
        }
    }

    pub fn decode_image(&self, encoded_bytes: Vec<u8>) {
        let tx = self.tx.clone();
        let color_image = Arc::clone(&self.color_image);
        self.runtime.spawn(async move {
            match flux::render::color::Context::decode_color_texture(&encoded_bytes) {
                Ok(image) => {
                    {
                        let mut boop = color_image.lock().unwrap();
                        *boop = Some(image);
                    }
                    if tx.send(Msg::DecodedImage).await.is_err() {
                        log::error!("Failed to send decoded image message");
                    }
                }
                Err(err) => log::error!("{}", err),
            }
        });
        log::debug!("Spawned image decoding task");
    }
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

struct FluxApp {
    mode: Mode,
    monitor: Option<MonitorHandle>,
    preferences: preferences::Preferences,
    mouse_exit: MouseExit,
    runtime: tokio::runtime::Runtime,
    window: Option<Arc<Window>>,
    gpu: Option<GpuState>,
    app: Option<App>,
    start: std::time::Instant,
    first_frame: Option<std::time::Instant>,
    clock: Option<clock_overlay::Clock>,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut logger =
        env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"));
    if let Ok(path) = std::env::current_exe() {
        if let Ok(file) = std::fs::File::create(path.with_file_name("Flux.log")) {
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
            if let Err(error) = preferences::configure() {
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
    };
    event_loop.run_app(&mut flux_app)?;
    Ok(())
}

// One event loop owns every display, so any exit request closes the entire saver.
struct MultiMonitorApp {
    mode: Mode,
    displays: Vec<FluxApp>,
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
        let preferences = preferences::load();
        log::info!("Loaded preferences: {preferences:?}");
        let clock_monitor = monitors
            .iter()
            .flatten()
            .find(|monitor| monitor.name().as_deref() == Some(preferences.clock_monitor.as_str()))
            .cloned()
            .or_else(|| event_loop.primary_monitor());
        for monitor in monitors {
            let mut display_preferences = preferences.clone();
            display_preferences.clock_enabled &=
                self.mode != Mode::Saver || monitor == clock_monitor;
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
                preferences: display_preferences,
                mouse_exit: MouseExit::default(),
                runtime: tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(1)
                    .enable_all()
                    .build()
                    .unwrap(),
                window: None,
                gpu: None,
                app: None,
                start: std::time::Instant::now(),
                first_frame: None,
                clock: None,
            };
            display.resumed(event_loop);
            self.displays.push(display);
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
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
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
            if let Some(window) = &display.window {
                let id = window.id();
                display.window_event(event_loop, id, WindowEvent::RedrawRequested);
            }
        }
    }
}
impl ApplicationHandler for FluxApp {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }

        let logical_size = winit::dpi::LogicalSize::new(1280, 800);

        #[cfg(target_os = "macos")]
        let window_attributes = Window::default_attributes()
            .with_title("Flux")
            .with_visible(false)
            .with_decorations(true)
            .with_resizable(true)
            .with_inner_size(logical_size)
            .with_title_hidden(true)
            .with_titlebar_transparent(true)
            .with_fullsize_content_view(true);

        #[cfg(not(target_os = "macos"))]
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
        #[cfg(target_os = "windows")]
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

        let wgpu_instance = wgpu::Instance::default();
        let window_surface = wgpu_instance.create_surface(window.clone()).unwrap();
        let adapter =
            pollster::block_on(wgpu_instance.request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                force_fallback_adapter: false,
                compatible_surface: Some(&window_surface),
                apply_limit_buckets: false,
            }))
            .expect("Failed to find an appropriate adapter");

        let limits = wgpu::Limits::default().using_resolution(adapter.limits());

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

        let (device, command_queue) =
            pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
                label: None,
                required_features: features,
                required_limits: limits,
                memory_hints: wgpu::MemoryHints::Performance,
                trace: wgpu::Trace::Off,
                experimental_features: wgpu::ExperimentalFeatures::disabled(),
            }))
            .expect("Failed to create device");

        let swapchain_capabilities = window_surface.get_capabilities(&adapter);
        let surface_output = get_preferred_surface_output(&swapchain_capabilities)
            .expect("Surface does not support a renderer-compatible color space");
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
        let scale_factor = window.scale_factor();
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
            desired_maximum_frame_latency: 2,
            alpha_mode: swapchain_capabilities.alpha_modes[0],
            view_formats: vec![],
            color_space: surface_output.color_space,
        };

        if size.is_some() {
            window_surface.configure(&device, &config);
        }
        if self.preferences.clock_enabled {
            self.clock = Some(clock_overlay::Clock::new(&device, surface_output.format));
            log::info!(
                "Clock enabled on {:?}",
                self.monitor.as_ref().and_then(|m| m.name())
            );
        }
        let settings = Arc::new(self.preferences.renderer_settings());
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
        )
        .unwrap();

        let (tx, rx) = mpsc::channel(32);

        // Take the runtime out temporarily to create the App
        let runtime = std::mem::replace(
            &mut self.runtime,
            tokio::runtime::Builder::new_current_thread()
                .build()
                .unwrap(),
        );

        self.app = Some(App {
            runtime,
            tx,
            rx,
            flux,
            _settings: settings,
            color_image: Arc::new(Mutex::new(None)),
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
        self.start = std::time::Instant::now();
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
        app.handle_pending_messages(&gpu.device, &gpu.command_queue);

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
            WindowEvent::DroppedFile(path) => {
                let bytes = std::fs::read(path).unwrap();
                app.decode_image(bytes);
                window.request_redraw();
            }
            WindowEvent::Resized(_) => {
                gpu.resize_pending = true;
                gpu.scale_factor = window.scale_factor();
                window.request_redraw();
            }
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                gpu.resize_pending = true;
                gpu.scale_factor = scale_factor;
                window.request_redraw();
            }
            WindowEvent::RedrawRequested => {
                gpu.resize_before_draw(window, &mut app.flux);
                if gpu.size.is_none() {
                    return;
                }
                let frame = match gpu.window_surface.get_current_texture() {
                    wgpu::CurrentSurfaceTexture::Success(frame)
                    | wgpu::CurrentSurfaceTexture::Suboptimal(frame) => frame,
                    wgpu::CurrentSurfaceTexture::Timeout
                    | wgpu::CurrentSurfaceTexture::Occluded => {
                        window.request_redraw();
                        return;
                    }
                    wgpu::CurrentSurfaceTexture::Outdated => {
                        gpu.window_surface.configure(&gpu.device, &gpu.config);
                        window.request_redraw();
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

                if let Some(clock) = &self.clock {
                    clock.draw(
                        &gpu.command_queue,
                        &mut encoder,
                        &view,
                        gpu.config.width,
                        gpu.config.height,
                        window.scale_factor(),
                    );
                }
                gpu.command_queue.submit(Some(encoder.finish()));
                window.pre_present_notify();
                gpu.command_queue.present(frame);
                if self.first_frame.is_none() {
                    self.first_frame = Some(std::time::Instant::now());
                    log::info!(
                        "First frame presented on {:?}; input exit arms in two seconds",
                        window.id()
                    );
                }
            }
            _ => (),
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        if let (Some(window), Some(gpu)) = (self.window.as_ref(), self.gpu.as_ref()) {
            if gpu.size.is_some() || gpu.resize_pending {
                window.request_redraw();
            }
        }
    }
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
