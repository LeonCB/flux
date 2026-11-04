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
    pub clock_enabled: bool,
    pub clock_monitor: String,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            palette: ColorPreset::Original,
            speed: 100,
            size: 100,
            quality: "Balanced".into(),
            clock_enabled: false,
            clock_monitor: "Primary".into(),
        }
    }
}

impl Preferences {
    pub fn parse(json: &str) -> Result<Self, String> {
        let prefs: Self = serde_json::from_str(json).map_err(|e| e.to_string())?;
        if ![50, 75, 100, 125, 150, 200].contains(&prefs.speed)
            || ![50, 75, 100, 125, 150, 200].contains(&prefs.size)
            || !["Low", "Balanced", "High"].contains(&prefs.quality.as_str())
            || prefs.clock_monitor.is_empty()
            || prefs.clock_monitor.len() > 64
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
}

pub fn path() -> Result<PathBuf, String> {
    std::env::var_os("LOCALAPPDATA")
        .map(|path| PathBuf::from(path).join("Flux").join("settings.json"))
        .ok_or_else(|| "The local application data folder is unavailable.".into())
}

pub fn load() -> Preferences {
    let result = path().and_then(|path| match std::fs::read_to_string(path) {
        Ok(json) => Preferences::parse(&json),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Preferences::default()),
        Err(error) => Err(error.to_string()),
    });
    match result {
        Ok(prefs) => prefs,
        Err(error) => {
            log::warn!("Cannot load preferences; using defaults: {error}");
            Preferences::default()
        }
    }
}

#[cfg(target_os = "windows")]
fn settings_command(script: &str, file: PathBuf) -> Result<std::process::Command, String> {
    use std::os::windows::process::CommandExt;
    // Embed the form so the installed .scr remains a standalone artifact.
    let powershell =
        PathBuf::from(std::env::var_os("SystemRoot").ok_or("SystemRoot is unavailable")?)
            .join("System32/WindowsPowerShell/v1.0/powershell.exe");
    let mut command = std::process::Command::new(powershell);
    command
        .args(["-NoProfile", "-STA", "-NonInteractive", "-Command", script])
        .env("FLUX_SETTINGS_PATH", file)
        .creation_flags(0x08000000); // CREATE_NO_WINDOW: display only the settings form.
    Ok(command)
}

#[cfg(target_os = "windows")]
pub fn configure() -> Result<(), String> {
    let status = settings_command(include_str!("settings-form.ps1"), path()?)?
        .status()
        .map_err(|error| error.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err("The settings window could not be opened or completed.".into())
    }
}

#[cfg(not(target_os = "windows"))]
pub fn configure() -> Result<(), String> {
    Err("Settings are currently available on Windows only.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "windows")]
    #[test]
    #[ignore = "opens a Windows Forms settings panel"]
    fn embedded_settings_form_saves_and_cancels_through_the_production_launcher() {
        let directory =
            std::env::temp_dir().join(format!("flux-settings-test-{}", std::process::id()));
        let path = directory.join("settings.json");
        let script = include_str!("settings-form.ps1")
            .replace("param([switch]$TestMode)", "$TestMode = $true");
        let output = settings_command(&script, path.clone())
            .unwrap()
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let saved = Preferences::parse(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(saved.palette, ColorPreset::Plasma);
        assert_eq!(saved.speed, 150);
        assert_eq!(saved.size, 125);
        assert_eq!(saved.quality, "High");
        assert!(saved.clock_enabled);
        assert_eq!(saved.clock_monitor, "Primary");
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(directory).unwrap();
    }
    #[test]
    fn defaults_and_partial_files_preserve_original_rendering() {
        assert_eq!(Preferences::parse("{}").unwrap(), Preferences::default());
        let prefs = Preferences::parse(r#"{"palette":"Poolside"}"#).unwrap();
        assert_eq!(prefs.speed, 100);
        assert!(!prefs.clock_enabled);
        assert_eq!(prefs.clock_monitor, "Primary");
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
            clock_enabled: true,
            clock_monitor: "Primary".into(),
        };
        let reloaded = Preferences::parse(&serde_json::to_string(&prefs).unwrap()).unwrap();
        assert_eq!(reloaded, prefs);
        let settings = reloaded.renderer_settings();
        assert_eq!(settings.fluid_size, 256);
        assert_eq!(settings.overall_scale, 2.0);
        assert_eq!(settings.line_width, flux::Settings::default().line_width);
    }
}
