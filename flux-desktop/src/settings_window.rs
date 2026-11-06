//! Native settings window (`Flux.exe /c`), built directly on Win32.
//!
//! The choices and their mapping to [`Preferences`] are platform independent
//! so they can be unit tested; only the window itself is Windows specific.

use crate::preferences::{self, Preferences};
use flux::settings::ColorPreset;

/// One dropdown: a Dutch label and its options as shown to the user.
pub struct Choice {
    pub label: &'static str,
    pub options: &'static [&'static str],
}

const PALETTES: [ColorPreset; 5] = [
    ColorPreset::Original,
    ColorPreset::Plasma,
    ColorPreset::Poolside,
    ColorPreset::Freedom,
    ColorPreset::Aurora,
];
const PERCENTAGES: [u32; 6] = [50, 75, 100, 125, 150, 200];
const QUALITIES: [&str; 3] = ["Low", "Balanced", "High"];
const FRAME_LIMITS: [u32; 3] = [30, 60, 0];

/// The dropdowns in window order. settings.json keeps the English values.
pub const CHOICES: [Choice; 6] = [
    Choice {
        label: "Kleurenpalet",
        options: &["Original", "Plasma", "Poolside", "Freedom", "Aurora"],
    },
    Choice {
        label: "Animatiesnelheid (%)",
        options: &["50", "75", "100", "125", "150", "200"],
    },
    Choice {
        label: "Lijndikte (%)",
        options: &["50", "75", "100", "125", "150", "200"],
    },
    Choice {
        label: "Simulatiekwaliteit",
        options: &["Laag", "Gemiddeld", "Hoog"],
    },
    Choice {
        label: "Beelden per seconde",
        options: &[
            "30 fps (zuinigst)",
            "60 fps (aanbevolen)",
            "Gelijk aan beeldscherm",
        ],
    },
    Choice {
        label: "Videokaart",
        options: &["Zuinig (ingebouwde GPU)", "Snelste videokaart"],
    },
];

fn position<T: PartialEq + ?Sized>(values: &[&T], value: &T) -> usize {
    values.iter().position(|v| *v == value).unwrap_or(0)
}

fn index_of<T: PartialEq>(values: &[T], value: &T) -> usize {
    values.iter().position(|v| v == value).unwrap_or(0)
}

fn pick<T: Copy>(values: &[T], index: usize) -> T {
    values[index.min(values.len() - 1)]
}

/// Selected option index per dropdown for the given preferences.
pub fn selection(prefs: &Preferences) -> [usize; 6] {
    [
        index_of(&PALETTES, &prefs.palette),
        index_of(&PERCENTAGES, &prefs.speed),
        index_of(&PERCENTAGES, &prefs.size),
        position(&QUALITIES, prefs.quality.as_str()),
        index_of(&FRAME_LIMITS, &prefs.frame_limit),
        position(&preferences::GPU_PREFERENCES, prefs.gpu.as_str()),
    ]
}

/// Preferences for the selected option index of each dropdown.
pub fn preferences_from(selection: [usize; 6]) -> Preferences {
    Preferences {
        palette: pick(&PALETTES, selection[0]),
        speed: pick(&PERCENTAGES, selection[1]),
        size: pick(&PERCENTAGES, selection[2]),
        quality: pick(&QUALITIES, selection[3]).into(),
        frame_limit: pick(&FRAME_LIMITS, selection[4]),
        gpu: pick(&preferences::GPU_PREFERENCES, selection[5]).into(),
    }
}

pub const HEADING: &str = "Stel Flux naar wens in";
pub const NOTE: &str = "Wijzigingen gaan in zodra Flux of het voorbeeld in Windows opnieuw start. \
Een hogere kwaliteit of meer beelden per seconde vraagt meer van de videokaart.";
pub const INVALID_FILE: &str = "De opgeslagen instellingen konden niet worden gelezen. \
De standaardwaarden worden getoond; Opslaan vervangt het bestand.";

pub use win32::run;

mod win32 {
    use super::*;
    use std::cell::Cell;
    use std::ffi::c_void;
    use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
    use windows_sys::Win32::Graphics::Gdi::{
        COLOR_BTNFACE, CreateFontW, DeleteObject, GetSysColorBrush, HFONT,
    };
    use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows_sys::Win32::UI::HiDpi::{AdjustWindowRectExForDpi, GetDpiForSystem};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::SetFocus;
    use windows_sys::Win32::UI::WindowsAndMessaging::*;

    const ID_RESTORE: usize = 100;
    /// Left-aligned, word-wrapping static text (`SS_LEFT`).
    const SS_LEFT: u32 = 0;
    const ID_COMBO: usize = 200;
    const COMBO_COUNT: usize = CHOICES.len();

    // The window lives on this thread only; WndProc reads its controls here.
    thread_local! {
        static COMBOS: Cell<[HWND; COMBO_COUNT]> =
            const { Cell::new([std::ptr::null_mut(); COMBO_COUNT]) };
    }

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    /// Scale a 96-DPI layout value to the system DPI.
    fn scale(value: i32, dpi: u32) -> i32 {
        value * dpi as i32 / 96
    }

    fn font(points: i32, dpi: u32) -> HFONT {
        let face = wide("Segoe UI");
        // Negative height selects the character height in pixels.
        unsafe {
            CreateFontW(
                -(points * dpi as i32 / 72),
                0,
                0,
                0,
                400,
                0,
                0,
                0,
                1, // DEFAULT_CHARSET
                0,
                0,
                5, // CLEARTYPE_QUALITY
                0,
                face.as_ptr(),
            )
        }
    }

    struct Layout {
        parent: HWND,
        dpi: u32,
        font: HFONT,
    }

    impl Layout {
        /// Create a child control at 96-DPI coordinates and give it the font.
        fn control(
            &self,
            class: &str,
            text: &str,
            style: u32,
            id: usize,
            bounds: (i32, i32, i32, i32),
        ) -> HWND {
            let class = wide(class);
            let text = wide(text);
            let (x, y, w, h) = bounds;
            unsafe {
                let hwnd = CreateWindowExW(
                    0,
                    class.as_ptr(),
                    text.as_ptr(),
                    WS_CHILD | WS_VISIBLE | style,
                    scale(x, self.dpi),
                    scale(y, self.dpi),
                    scale(w, self.dpi),
                    scale(h, self.dpi),
                    self.parent,
                    id as _,
                    GetModuleHandleW(std::ptr::null()),
                    std::ptr::null(),
                );
                SendMessageW(hwnd, WM_SETFONT, self.font as WPARAM, 1);
                hwnd
            }
        }
    }

    fn select(selection: [usize; COMBO_COUNT]) {
        for (combo, index) in COMBOS.get().into_iter().zip(selection) {
            unsafe { SendMessageW(combo, CB_SETCURSEL, index, 0) };
        }
    }

    fn selected() -> [usize; COMBO_COUNT] {
        COMBOS
            .get()
            .map(|combo| unsafe { SendMessageW(combo, CB_GETCURSEL, 0, 0) }.max(0) as usize)
    }

    fn message(owner: HWND, text: &str) {
        let title = wide("Flux");
        let text = wide(text);
        unsafe { MessageBoxW(owner, text.as_ptr(), title.as_ptr(), MB_OK | MB_ICONWARNING) };
    }

    unsafe extern "system" fn window_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        match msg {
            WM_COMMAND => {
                match wparam & 0xFFFF {
                    id if id == IDOK as usize => {
                        let prefs = preferences_from(selected());
                        match preferences::path().and_then(|path| preferences::save(&path, &prefs))
                        {
                            Ok(()) => unsafe {
                                DestroyWindow(hwnd);
                            },
                            Err(error) => message(
                                hwnd,
                                &format!(
                                    "Flux-instellingen konden niet worden opgeslagen:\n{error}"
                                ),
                            ),
                        }
                    }
                    id if id == IDCANCEL as usize => unsafe {
                        DestroyWindow(hwnd);
                    },
                    ID_RESTORE => select(selection(&Preferences::default())),
                    _ => {}
                }
                0
            }
            WM_DESTROY => {
                unsafe { PostQuitMessage(0) };
                0
            }
            _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
        }
    }

    pub fn run() -> Result<(), String> {
        let (prefs, invalid) = preferences::load_for_editing();
        unsafe {
            let instance = GetModuleHandleW(std::ptr::null());
            let class_name = wide("FluxSettings");
            // Resource 1 is the application icon from flux.rc.
            let icon = LoadIconW(instance, 1 as _);
            let class = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                style: CS_HREDRAW | CS_VREDRAW,
                lpfnWndProc: Some(window_proc),
                cbClsExtra: 0,
                cbWndExtra: 0,
                hInstance: instance,
                hIcon: icon,
                hCursor: LoadCursorW(std::ptr::null_mut(), IDC_ARROW),
                hbrBackground: GetSysColorBrush(COLOR_BTNFACE),
                lpszMenuName: std::ptr::null(),
                lpszClassName: class_name.as_ptr(),
                hIconSm: icon,
            };
            if RegisterClassExW(&class) == 0 {
                return Err("Het instellingenvenster kon niet worden geregistreerd.".into());
            }

            let dpi = GetDpiForSystem();
            let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU;
            let mut rect = RECT {
                left: 0,
                top: 0,
                right: scale(460, dpi),
                bottom: scale(462, dpi),
            };
            AdjustWindowRectExForDpi(&mut rect, style, 0, 0, dpi);
            let (width, height) = (rect.right - rect.left, rect.bottom - rect.top);
            let title = wide("Flux-instellingen");
            let hwnd = CreateWindowExW(
                WS_EX_DLGMODALFRAME,
                class_name.as_ptr(),
                title.as_ptr(),
                style,
                (GetSystemMetrics(SM_CXSCREEN) - width) / 2,
                (GetSystemMetrics(SM_CYSCREEN) - height) / 2,
                width,
                height,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                instance,
                std::ptr::null::<c_void>(),
            );
            if hwnd.is_null() {
                return Err("Het instellingenvenster kon niet worden geopend.".into());
            }

            let body = font(10, dpi);
            let heading_font = font(15, dpi);
            let layout = Layout {
                parent: hwnd,
                dpi,
                font: body,
            };
            let heading = layout.control("STATIC", HEADING, SS_LEFT, 0, (24, 18, 410, 35));
            SendMessageW(heading, WM_SETFONT, heading_font as WPARAM, 1);

            let mut combos = [std::ptr::null_mut(); COMBO_COUNT];
            for (index, choice) in CHOICES.iter().enumerate() {
                let top = 70 + 42 * index as i32;
                // The label is created just before its dropdown so screen
                // readers announce it as the dropdown's name.
                layout.control("STATIC", choice.label, SS_LEFT, 0, (24, top + 4, 170, 26));
                let combo = layout.control(
                    "COMBOBOX",
                    "",
                    CBS_DROPDOWNLIST as u32 | WS_VSCROLL | WS_TABSTOP,
                    ID_COMBO + index,
                    (200, top, 232, 220),
                );
                for option in choice.options {
                    let option = wide(option);
                    SendMessageW(combo, CB_ADDSTRING, 0, option.as_ptr() as LPARAM);
                }
                combos[index] = combo;
            }
            COMBOS.set(combos);
            select(selection(&prefs));

            let note = if invalid { INVALID_FILE } else { NOTE };
            layout.control("STATIC", note, SS_LEFT, 0, (24, 328, 410, 60));
            layout.control(
                "BUTTON",
                "Standaardwaarden",
                BS_PUSHBUTTON as u32 | WS_TABSTOP,
                ID_RESTORE,
                (24, 406, 150, 32),
            );
            layout.control(
                "BUTTON",
                "Annuleren",
                BS_PUSHBUTTON as u32 | WS_TABSTOP,
                IDCANCEL as usize,
                (236, 406, 90, 32),
            );
            layout.control(
                "BUTTON",
                "Opslaan",
                BS_DEFPUSHBUTTON as u32 | WS_TABSTOP,
                IDOK as usize,
                (338, 406, 94, 32),
            );

            ShowWindow(hwnd, SW_SHOW);
            SetForegroundWindow(hwnd);
            SetFocus(combos[0]);

            // IsDialogMessage provides Tab navigation, Enter (Opslaan) and
            // Esc (Annuleren) in this plain window.
            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                if IsDialogMessageW(hwnd, &msg) == 0 {
                    TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }

            DeleteObject(body as _);
            DeleteObject(heading_font as _);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_choice_has_a_value_for_each_option() {
        let counts = [
            PALETTES.len(),
            PERCENTAGES.len(),
            PERCENTAGES.len(),
            QUALITIES.len(),
            FRAME_LIMITS.len(),
            preferences::GPU_PREFERENCES.len(),
        ];
        for (choice, count) in CHOICES.iter().zip(counts) {
            assert_eq!(choice.options.len(), count, "{}", choice.label);
        }
    }

    #[test]
    fn defaults_select_the_recommended_options() {
        let selected = selection(&Preferences::default());
        assert_eq!(CHOICES[3].options[selected[3]], "Gemiddeld");
        assert_eq!(CHOICES[4].options[selected[4]], "60 fps (aanbevolen)");
        assert_eq!(CHOICES[5].options[selected[5]], "Zuinig (ingebouwde GPU)");
        assert_eq!(preferences_from(selected), Preferences::default());
    }

    #[test]
    fn every_selection_round_trips_through_valid_preferences() {
        for (choice, _) in CHOICES.iter().enumerate() {
            for option in 0..CHOICES[choice].options.len() {
                let mut selected = selection(&Preferences::default());
                selected[choice] = option;
                let prefs = preferences_from(selected);
                let json = serde_json::to_string(&prefs).unwrap();
                assert_eq!(Preferences::parse(&json).unwrap(), prefs);
                assert_eq!(selection(&prefs), selected);
            }
        }
    }
}
