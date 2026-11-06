use std::time::Duration;

pub fn input_armed(since_first_frame: Option<Duration>) -> bool {
    since_first_frame.is_some_and(|elapsed| elapsed >= Duration::from_secs(2))
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Mode {
    Desktop,
    Saver,
    Configure,
    Preview(usize),
}

impl Mode {
    pub fn parse(args: &[String], is_scr: bool) -> Result<Self, &'static str> {
        let Some(first) = args.first() else {
            return Ok(if is_scr {
                Self::Configure
            } else {
                Self::Desktop
            });
        };
        let flag = first.to_ascii_lowercase();
        match flag.as_str() {
            "--windowed" if args.len() == 1 => Ok(Self::Desktop),
            "/s" | "-s" if args.len() == 1 => Ok(Self::Saver),
            "/c" | "-c" => Ok(Self::Configure),
            "/p" | "-p" if args.len() == 2 => parse_preview_handle(&args[1]),
            _ if flag.starts_with("/c:") || flag.starts_with("-c:") => Ok(Self::Configure),
            _ if (flag.starts_with("/p:") || flag.starts_with("-p:")) && args.len() == 1 => {
                parse_preview_handle(&flag[3..])
            }
            _ => Err(
                "Unknown argument. Use /s for the screensaver or --windowed for the desktop prototype.",
            ),
        }
    }
}

#[derive(Default)]
pub struct MouseExit {
    origin: Option<(f64, f64)>,
}

impl MouseExit {
    pub fn moved(&mut self, elapsed: Duration, x: f64, y: f64) -> bool {
        // Ignore synthetic startup motion and give the launch click time to settle.
        if elapsed < Duration::from_secs(2) {
            self.origin = Some((x, y));
            return false;
        }
        let (ox, oy) = *self.origin.get_or_insert((x, y));
        (x - ox).hypot(y - oy) >= 8.0
    }
}

pub fn show_message(message: &str) {
    let title: Vec<u16> = "Flux\0".encode_utf16().collect();
    let text: Vec<u16> = message.encode_utf16().chain(Some(0)).collect();
    // Both strings are null-terminated and live until MessageBoxW returns.
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::MessageBoxW(
            std::ptr::null_mut(),
            text.as_ptr(),
            title.as_ptr(),
            windows_sys::Win32::UI::WindowsAndMessaging::MB_OK,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn startup_keyboard_events_cannot_exit_before_first_frame_or_during_grace() {
        assert!(!input_armed(None));
        assert!(!input_armed(Some(Duration::ZERO)));
        assert!(!input_armed(Some(Duration::from_millis(1999))));
        assert!(input_armed(Some(Duration::from_secs(2))));
    }

    fn parse(args: &[&str], scr: bool) -> Result<Mode, &'static str> {
        Mode::parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>(), scr)
    }

    #[test]
    fn launch_modes_are_case_insensitive_and_safe_for_preview() {
        assert_eq!(parse(&[], false), Ok(Mode::Desktop));
        assert_eq!(parse(&[], true), Ok(Mode::Configure));
        for flag in ["/s", "/S", "-s"] {
            assert_eq!(parse(&[flag], true), Ok(Mode::Saver));
        }
        assert_eq!(parse(&["/P", "1234"], true), Ok(Mode::Preview(1234)));
        assert_eq!(parse(&["/p:1234"], true), Ok(Mode::Preview(1234)));
        assert_eq!(parse(&["/C:1234"], true), Ok(Mode::Configure));
        assert_eq!(parse(&["--windowed"], true), Ok(Mode::Desktop));
        assert!(parse(&["/unknown"], true).is_err());
    }

    #[test]
    fn invalid_preview_handles_are_rejected() {
        for args in [
            vec!["/p"],
            vec!["/p", "0"],
            vec!["/p", "-1"],
            vec!["/p:abc"],
            vec!["/p:"],
            vec!["/p", "18446744073709551616"],
            vec!["/p", "1234", "extra"],
        ] {
            assert!(parse(&args, true).is_err(), "{args:?}");
        }
    }

    #[test]
    fn mouse_ignores_startup_and_jitter_but_accumulates_motion() {
        let mut mouse = MouseExit::default();
        assert!(!mouse.moved(Duration::ZERO, 100.0, 100.0));
        assert!(!mouse.moved(Duration::from_millis(500), 200.0, 200.0));
        assert!(!mouse.moved(Duration::from_secs(2), 203.0, 201.0));
        assert!(mouse.moved(Duration::from_secs(2), 208.0, 200.0));
        let mut mouse = MouseExit::default();
        assert!(!mouse.moved(Duration::from_secs(2), 500.0, 500.0));
        assert!(mouse.moved(Duration::from_secs(2), 510.0, 500.0));
    }
}

fn parse_preview_handle(value: &str) -> Result<Mode, &'static str> {
    value
        .parse::<usize>()
        .ok()
        .filter(|handle| *handle != 0 && *handle <= isize::MAX as usize)
        .map(Mode::Preview)
        .ok_or("Preview requires a valid nonzero window handle: /p <HWND>.")
}

/// Read the host's current client area; a missing host ends the preview.
pub fn preview_size(handle: usize) -> Option<winit::dpi::PhysicalSize<u32>> {
    use windows_sys::Win32::{
        Foundation::RECT,
        UI::WindowsAndMessaging::{GetClientRect, IsWindow},
    };
    let hwnd = handle as *mut std::ffi::c_void;
    let mut rect = RECT::default();
    // Win32 validates the foreign HWND. No pointer supplied by the caller is dereferenced.
    unsafe {
        if IsWindow(hwnd) == 0 || GetClientRect(hwnd, &mut rect) == 0 {
            return None;
        }
    }
    Some(winit::dpi::PhysicalSize::new(
        (rect.right - rect.left).max(0) as u32,
        (rect.bottom - rect.top).max(0) as u32,
    ))
}


/// Whether Windows reports the console display as off. Updated by
/// [`DisplayPowerWatch`]; while it is off there is nothing to draw for.
static DISPLAY_OFF: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn display_off() -> bool {
    DISPLAY_OFF.load(std::sync::atomic::Ordering::Relaxed)
}

/// Subscription to display on/off notifications; unsubscribes when dropped.
pub struct DisplayPowerWatch {
    handle: windows_sys::Win32::System::Power::HPOWERNOTIFY,
    // Windows keeps a pointer to these parameters while subscribed.
    _parameters: Box<windows_sys::Win32::System::Power::DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS>,
}

impl DisplayPowerWatch {
    pub fn start() -> Option<Self> {
        use windows_sys::Win32::System::Power::{
            DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS, RegisterPowerSettingNotification,
        };
        use windows_sys::Win32::UI::WindowsAndMessaging::DEVICE_NOTIFY_CALLBACK;
        let parameters = Box::new(DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS {
            Callback: Some(display_state_changed),
            Context: std::ptr::null_mut(),
        });
        // Windows reports the current state right after subscribing.
        let handle = unsafe {
            RegisterPowerSettingNotification(
                &*parameters as *const DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS as _,
                &GUID_CONSOLE_DISPLAY_STATE,
                DEVICE_NOTIFY_CALLBACK,
            )
        };
        if handle == 0 {
            log::warn!("Cannot watch the display power state; drawing continues while it is off");
            return None;
        }
        Some(Self {
            handle,
            _parameters: parameters,
        })
    }
}

impl Drop for DisplayPowerWatch {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::System::Power::UnregisterPowerSettingNotification(self.handle)
        };
    }
}

/// GUID_CONSOLE_DISPLAY_STATE: data is 0 (off), 1 (on) or 2 (dimmed).
const GUID_CONSOLE_DISPLAY_STATE: windows_sys::core::GUID =
    windows_sys::core::GUID::from_u128(0x6fe69556_704a_47a0_8f24_c28d936fda47);

unsafe extern "system" fn display_state_changed(
    _context: *const std::ffi::c_void,
    kind: u32,
    setting: *const std::ffi::c_void,
) -> u32 {
    use windows_sys::Win32::System::Power::POWERBROADCAST_SETTING;
    use windows_sys::Win32::UI::WindowsAndMessaging::PBT_POWERSETTINGCHANGE;
    if kind != PBT_POWERSETTINGCHANGE || setting.is_null() {
        return 0;
    }
    // Windows passes a POWERBROADCAST_SETTING with at least one data byte.
    let setting = unsafe { &*(setting as *const POWERBROADCAST_SETTING) };
    let (guid, expected) = (setting.PowerSetting, GUID_CONSOLE_DISPLAY_STATE);
    let is_display_state = (guid.data1, guid.data2, guid.data3, guid.data4)
        == (
            expected.data1,
            expected.data2,
            expected.data3,
            expected.data4,
        );
    if is_display_state && setting.DataLength >= 1 {
        let off = setting.Data[0] == 0;
        let was_off = DISPLAY_OFF.swap(off, std::sync::atomic::Ordering::Relaxed);
        if off != was_off {
            log::info!(
                "Display turned {}",
                if off { "off; pausing" } else { "on; resuming" }
            );
        }
    }
    0
}


#[cfg(test)]
mod display_power_tests {
    use super::*;
    use windows_sys::Win32::System::Power::POWERBROADCAST_SETTING;
    use windows_sys::Win32::UI::WindowsAndMessaging::PBT_POWERSETTINGCHANGE;

    fn notify(state: u8) {
        let setting = POWERBROADCAST_SETTING {
            PowerSetting: GUID_CONSOLE_DISPLAY_STATE,
            DataLength: 4,
            Data: [state],
        };
        let pointer = &setting as *const POWERBROADCAST_SETTING as *const std::ffi::c_void;
        unsafe { display_state_changed(std::ptr::null(), PBT_POWERSETTINGCHANGE, pointer) };
    }

    #[test]
    fn pauses_only_while_the_display_is_off() {
        notify(0);
        assert!(display_off());
        notify(2); // dimmed: still visible, keep drawing
        assert!(!display_off());
        notify(0);
        notify(1);
        assert!(!display_off());
        // Other notifications are ignored.
        unsafe { display_state_changed(std::ptr::null(), 0, std::ptr::null()) };
        assert!(!display_off());
    }
}
