use flux::settings::{ColorMode, ColorPreset};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Preferences {
    pub palette: ColorPreset,
    pub speed: u32,
    pub size: u32,
    pub quality: String,
    /// Maximum frames per second; 0 follows the display refresh rate.
    pub frame_limit: u32,
    /// "LowPower" (integrated GPU) or "HighPerformance" (discrete GPU).
    pub gpu: String,
}

pub const FRAME_LIMITS: [u32; 3] = [0, 30, 60];
pub const GPU_PREFERENCES: [&str; 2] = ["LowPower", "HighPerformance"];

impl Default for Preferences {
    fn default() -> Self {
        Self {
            palette: ColorPreset::Original,
            speed: 100,
            size: 100,
            quality: "Balanced".into(),
            frame_limit: 60,
            gpu: "LowPower".into(),
        }
    }
}

impl Preferences {
    pub fn parse(json: &str) -> Result<Self, String> {
        let prefs: Self = serde_json::from_str(json).map_err(|e| e.to_string())?;
        if ![50, 75, 100, 125, 150, 200].contains(&prefs.speed)
            || ![50, 75, 100, 125, 150, 200].contains(&prefs.size)
            || !["Low", "Balanced", "High"].contains(&prefs.quality.as_str())
            || !FRAME_LIMITS.contains(&prefs.frame_limit)
            || !GPU_PREFERENCES.contains(&prefs.gpu.as_str())
        {
            return Err("Unsupported preference value".into());
        }
        Ok(prefs)
    }

    pub fn renderer_settings(&self) -> flux::Settings {
        flux::Settings {
            color_mode: ColorMode::Preset(self.palette),
            overall_scale: self.size as f32 / 100.0,
            fluid_size: match self.quality.as_str() {
                "Low" => 64,
                "High" => 256,
                _ => 128,
            },
            ..Default::default()
        }
    }

    pub fn power_preference(&self) -> wgpu::PowerPreference {
        if self.gpu == "HighPerformance" {
            wgpu::PowerPreference::HighPerformance
        } else {
            wgpu::PowerPreference::LowPower
        }
    }
}

pub fn path() -> Result<PathBuf, String> {
    std::env::var_os("LOCALAPPDATA")
        .map(|path| PathBuf::from(path).join("Flux").join("settings.json"))
        .ok_or_else(|| "The local application data folder is unavailable.".into())
}

/// Read settings.json; `Err` means the file exists but cannot be used.
fn read() -> Result<Preferences, String> {
    let path = path()?;
    match std::fs::read_to_string(path) {
        Ok(json) => Preferences::parse(&json),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Preferences::default()),
        Err(error) => Err(error.to_string()),
    }
}

pub fn load() -> Preferences {
    read().unwrap_or_else(|error| {
        log::warn!("Cannot load preferences; using defaults: {error}");
        Preferences::default()
    })
}

/// Preferences for the settings window, plus whether the file was unusable.
pub fn load_for_editing() -> (Preferences, bool) {
    match read() {
        Ok(prefs) => (prefs, false),
        Err(error) => {
            log::warn!("Cannot load preferences; showing defaults: {error}");
            (Preferences::default(), true)
        }
    }
}

/// Write preferences via a temporary file, so a failed save never leaves a
/// half-written settings.json behind.
pub fn save(path: &std::path::Path, prefs: &Preferences) -> Result<(), String> {
    if let Some(directory) = path.parent() {
        std::fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    }
    let json = serde_json::to_string_pretty(prefs).map_err(|error| error.to_string())?;
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, json).map_err(|error| error.to_string())?;
    std::fs::rename(&temporary, path).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn save_writes_a_file_that_loads_back() {
        let directory =
            std::env::temp_dir().join(format!("flux-settings-test-{}", std::process::id()));
        let path = directory.join("settings.json");
        let prefs = Preferences {
            palette: ColorPreset::Aurora,
            frame_limit: 30,
            ..Default::default()
        };
        save(&path, &prefs).unwrap();
        save(&path, &prefs).unwrap(); // replacing an existing file works too
        let json = std::fs::read_to_string(&path).unwrap();
        assert_eq!(Preferences::parse(&json).unwrap(), prefs);
        assert!(!path.with_extension("json.tmp").exists());
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn defaults_and_partial_files_preserve_original_rendering() {
        assert_eq!(Preferences::parse("{}").unwrap(), Preferences::default());
        let prefs =
            Preferences::parse(r#"{"palette":"Poolside","clockEnabled":true,"clockMonitor":"x"}"#)
                .unwrap();
        assert_eq!(prefs.speed, 100);
        assert_eq!(prefs.frame_limit, 60);
        assert_eq!(prefs.power_preference(), wgpu::PowerPreference::LowPower);
        assert_eq!(
            prefs.renderer_settings().color_mode,
            ColorMode::Preset(ColorPreset::Poolside)
        );
        assert_eq!(
            prefs.renderer_settings().fluid_size,
            flux::Settings::default().fluid_size
        );
    }
    #[test]
    fn rejects_corrupt_or_out_of_range_preferences() {
        for value in [
            "not json",
            r#"{"speed":0}"#,
            r#"{"size":10000}"#,
            r#"{"quality":"Ultra"}"#,
            r#"{"palette":"Unknown"}"#,
            r#"{"speed":null}"#,
            r#"{"frameLimit":45}"#,
            r#"{"gpu":"Fastest"}"#,
        ] {
            assert!(Preferences::parse(value).is_err());
        }
    }
    #[test]
    fn round_trip_maps_user_choices_without_changing_base_units() {
        let prefs = Preferences {
            palette: ColorPreset::Plasma,
            speed: 150,
            size: 200,
            quality: "High".into(),
            frame_limit: 0,
            gpu: "HighPerformance".into(),
        };
        let reloaded = Preferences::parse(&serde_json::to_string(&prefs).unwrap()).unwrap();
        assert_eq!(reloaded, prefs);
        let settings = reloaded.renderer_settings();
        assert_eq!(settings.fluid_size, 256);
        assert_eq!(settings.overall_scale, 2.0);
        assert_eq!(settings.line_width, flux::Settings::default().line_width);
    }
}
