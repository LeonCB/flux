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
            _ if (flag.starts_with("/p:") || flag.starts_with("-p:")) && args.len() == 1 => parse_preview_handle(&flag[3..]),
            _ => Err("Unknown argument. Use /s for the screensaver or --windowed for the desktop prototype."),
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
    #[cfg(target_os = "windows")]
    {
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
    #[cfg(not(target_os = "windows"))]
    eprintln!("Flux: {message}");
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
#[cfg(target_os = "windows")]
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

#[cfg(not(target_os = "windows"))]
pub fn preview_size(_handle: usize) -> Option<winit::dpi::PhysicalSize<u32>> {
    None
}
