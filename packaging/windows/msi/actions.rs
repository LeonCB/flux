//! Native, per-user MSI actions. File ownership stays with Windows Installer.
//! Registry snapshots preserve both value type and bytes for exact rollback.
use std::{cell::RefCell, ffi::c_void, ptr};
thread_local! { static USER_SID: RefCell<String> = const { RefCell::new(String::new()) }; }
type Key = *mut c_void;
const DESKTOP: &str = "Control Panel\\Desktop";
#[cfg(feature = "candidate-identity")]
const STATE: &str = "Software\\Flux\\WindowsInstaller";
#[cfg(not(feature = "candidate-identity"))]
const STATE: &str = "Software\\Flux\\Installer";
const SELECTION: &str = "SCRNSAVE.EXE";
const PREVIOUS: &str = "PreviousSelection";
const LEGACY_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{AE5327E7-474B-47B6-BF01-2D5352A418AF}_is1";
type Value = Option<(u32, Vec<u8>)>;
#[link(name = "advapi32")]
extern "system" {
    fn RegOpenKeyExW(key: Key, path: *const u16, options: u32, access: u32, out: *mut Key) -> i32;
    fn RegCreateKeyExW(
        key: Key,
        path: *const u16,
        reserved: u32,
        class: *mut u16,
        options: u32,
        access: u32,
        security: *const c_void,
        out: *mut Key,
        disposition: *mut u32,
    ) -> i32;
    fn RegQueryValueExW(
        key: Key,
        name: *const u16,
        reserved: *mut u32,
        kind: *mut u32,
        data: *mut u8,
        len: *mut u32,
    ) -> i32;
    fn RegSetValueExW(
        key: Key,
        name: *const u16,
        reserved: u32,
        kind: u32,
        data: *const u8,
        len: u32,
    ) -> i32;
    fn RegDeleteValueW(key: Key, name: *const u16) -> i32;
    fn RegCloseKey(key: Key) -> i32;
}
#[link(name = "msi")]
extern "system" {
    fn MsiGetPropertyW(handle: u32, name: *const u16, value: *mut u16, len: *mut u32) -> u32;
    fn MsiSetPropertyW(handle: u32, name: *const u16, value: *const u16) -> u32;
    fn MsiCreateRecord(fields: u32) -> u32;
    fn MsiRecordSetStringW(record: u32, field: u32, value: *const u16) -> u32;
    fn MsiProcessMessage(handle: u32, kind: u32, record: u32) -> i32;
    fn MsiCloseHandle(handle: u32) -> u32;
}
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}
fn checked(code: i32) -> Result<(), String> {
    if code == 0 {
        Ok(())
    } else {
        Err(format!("Windows error {code}"))
    }
}
struct OwnedKey(Key);
impl Drop for OwnedKey {
    fn drop(&mut self) {
        unsafe {
            RegCloseKey(self.0);
        }
    }
}
fn open(path: &str, create: bool) -> Result<Option<OwnedKey>, String> {
    let sid = USER_SID.with(|s| s.borrow().clone());
    if !sid.starts_with("S-1-")
        || !sid
            .bytes()
            .all(|b| b == b'S' || b == b'-' || b.is_ascii_digit())
    {
        return Err("Invalid installer user SID".into());
    }
    let root = (0x80000003u32 as i32 as isize) as Key; // HKEY_USERS, explicit identity.
    let path = format!("{sid}\\{path}");
    let mut key = ptr::null_mut();
    let code = unsafe {
        if create {
            RegCreateKeyExW(
                root,
                wide(&path).as_ptr(),
                0,
                ptr::null_mut(),
                0,
                0x20019 | 0x20006 | 0x100,
                ptr::null(),
                &mut key,
                ptr::null_mut(),
            )
        } else {
            RegOpenKeyExW(root, wide(&path).as_ptr(), 0, 0x20019 | 0x100, &mut key)
        }
    };
    if code == 2 {
        return Ok(None);
    }
    checked(code)?;
    Ok(Some(OwnedKey(key)))
}
fn read(path: &str, name: &str) -> Result<Value, String> {
    let Some(key) = open(path, false)? else {
        return Ok(None);
    };
    let (mut kind, mut len) = (0, 0);
    let code = unsafe {
        RegQueryValueExW(
            key.0,
            wide(name).as_ptr(),
            ptr::null_mut(),
            &mut kind,
            ptr::null_mut(),
            &mut len,
        )
    };
    if code == 2 {
        return Ok(None);
    }
    checked(code)?;
    if len > 65536 {
        return Err("Registry value is too large".into());
    }
    let mut data = vec![0; len as usize];
    unsafe {
        checked(RegQueryValueExW(
            key.0,
            wide(name).as_ptr(),
            ptr::null_mut(),
            &mut kind,
            data.as_mut_ptr(),
            &mut len,
        ))?;
    }
    data.truncate(len as usize);
    Ok(Some((kind, data)))
}
fn write(path: &str, name: &str, value: &Value) -> Result<(), String> {
    let key = open(path, true)?.ok_or("Cannot open registry key")?;
    let code = unsafe {
        match value {
            Some((kind, bytes)) => RegSetValueExW(
                key.0,
                wide(name).as_ptr(),
                0,
                *kind,
                bytes.as_ptr(),
                bytes.len() as u32,
            ),
            None => RegDeleteValueW(key.0, wide(name).as_ptr()),
        }
    };
    if value.is_none() && code == 2 {
        Ok(())
    } else {
        checked(code)
    }
}
fn string(s: &str) -> Value {
    Some((1, wide(s).iter().flat_map(|c| c.to_le_bytes()).collect()))
}
fn text(value: &Value) -> Result<String, String> {
    let Some((kind, bytes)) = value else {
        return Err("Missing registry value".into());
    };
    if ![1, 2].contains(kind) || bytes.len() % 2 != 0 {
        return Err("Invalid registry string".into());
    }
    let chars: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|b| u16::from_le_bytes([b[0], b[1]]))
        .take_while(|c| *c != 0)
        .collect();
    String::from_utf16(&chars).map_err(|e| e.to_string())
}
fn encode(value: &Value) -> String {
    match value {
        None => "-".into(),
        Some((kind, bytes)) => format!(
            "{kind}:{}",
            bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
        ),
    }
}
fn decode(s: &str) -> Result<Value, String> {
    if s == "-" {
        return Ok(None);
    }
    let (kind, hex) = s.split_once(':').ok_or("Invalid snapshot")?;
    if hex.len() % 2 != 0 || !hex.is_ascii() {
        return Err("Invalid snapshot data".into());
    }
    let bytes = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).map_err(|e| e.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Some((
        kind.parse::<u32>().map_err(|e| e.to_string())?,
        bytes,
    )))
}
fn property(handle: u32, name: &str) -> Result<String, String> {
    let mut len = 0;
    let mut empty = 0u16;
    let code = unsafe { MsiGetPropertyW(handle, wide(name).as_ptr(), &mut empty, &mut len) };
    if code != 0 && code != 234 {
        return Err(format!("MSI property error {code}"));
    }
    let mut data = vec![0; len as usize + 1];
    len += 1;
    unsafe {
        checked(MsiGetPropertyW(handle, wide(name).as_ptr(), data.as_mut_ptr(), &mut len) as i32)?;
    }
    String::from_utf16(&data[..len as usize]).map_err(|e| e.to_string())
}
fn set(handle: u32, name: &str, value: &str) -> Result<(), String> {
    unsafe { checked(MsiSetPropertyW(handle, wide(name).as_ptr(), wide(value).as_ptr()) as i32) }
}
fn log(handle: u32, message: &str) {
    unsafe {
        let record = MsiCreateRecord(0);
        MsiRecordSetStringW(record, 0, wide(message).as_ptr());
        MsiProcessMessage(handle, 0x04000000, record);
        MsiCloseHandle(record);
    }
}
fn run(handle: u32, action: impl FnOnce() -> Result<(), String>) -> u32 {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(action)) {
        Ok(Ok(())) => 0,
        result => {
            let message = match result {
                Ok(Err(e)) => e,
                _ => "Unexpected native action failure".into(),
            };
            unsafe {
                let record = MsiCreateRecord(0);
                MsiRecordSetStringW(record, 0, wide(&format!("Flux MSI: {message}")).as_ptr());
                MsiProcessMessage(handle, 0x01000000, record);
                MsiCloseHandle(record);
            }
            1603
        }
    }
}

fn identity(handle: u32) -> Result<String, String> {
    let sid = property(handle, "UserSID")?;
    USER_SID.with(|s| *s.borrow_mut() = sid.clone());
    Ok(sid)
}
fn same_path(a: &str, b: &str) -> bool {
    a.trim_matches('"')
        .replace('/', "\\")
        .eq_ignore_ascii_case(&b.trim_matches('"').replace('/', "\\"))
}
fn legacy_original(folder: &str) -> Result<Value, String> {
    let manifest = std::path::Path::new(folder).join("installation.json");
    if std::fs::metadata(&manifest)
        .map_err(|e| e.to_string())?
        .len()
        > 65536
    {
        return Err("Legacy metadata is too large".into());
    }
    let value: serde_json::Value =
        serde_json::from_slice(&std::fs::read(manifest).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
    if value["schema"].as_u64() != Some(1) {
        return Err("Unsupported legacy metadata".into());
    }
    match value.get("previousScreenSaver") {
        Some(serde_json::Value::Null) => Ok(None),
        Some(serde_json::Value::String(s)) => Ok(string(s)),
        _ => Err("Invalid legacy screensaver selection".into()),
    }
}
fn legacy_uninstaller(handle: u32, folder: &str) -> Result<Option<String>, String> {
    let snapshot_location = property(handle, "LEGACY_LOCATION")?;
    let snapshot_command = property(handle, "LEGACY_UNINSTALL")?;
    let location = if snapshot_location.is_empty() {
        read(LEGACY_KEY, "InstallLocation")?
    } else {
        string(&snapshot_location)
    };
    if location.is_none() {
        return Ok(None);
    }
    if !same_path(
        text(&location)?.trim_end_matches(['\\', '/']),
        folder.trim_end_matches(['\\', '/']),
    ) {
        return Ok(None);
    }
    let command = if snapshot_location.is_empty() {
        text(&read(LEGACY_KEY, "UninstallString")?)?
    } else {
        snapshot_command
    };
    let path = command.trim().trim_matches('"');
    let executable = std::path::Path::new(path);
    let name = executable
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let suffix = name
        .strip_prefix("unins")
        .and_then(|s| s.strip_suffix(".exe"));
    if !executable.is_absolute()
        || !executable
            .parent()
            .is_some_and(|p| same_path(&p.to_string_lossy(), folder.trim_end_matches(['\\', '/'])))
        || !suffix.is_some_and(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
        || !executable.is_file()
    {
        return Err("The registered legacy uninstaller is not a valid Inno Setup executable in its installation directory".into());
    }
    Ok(Some(path.into()))
}
fn reject_reparse_ancestors(path: &std::path::Path) -> Result<(), String> {
    use std::os::windows::fs::MetadataExt;
    for entry in path.ancestors() {
        match std::fs::symlink_metadata(entry) {
            Ok(metadata) if metadata.file_attributes() & 0x400 != 0 => {
                return Err("Redirected installation paths are not supported".into())
            }
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(())
}
fn probe_binary(path: &str) -> Result<(), String> {
    reject_reparse_ancestors(std::path::Path::new(path))?;
    use std::os::windows::fs::OpenOptionsExt;
    if std::path::Path::new(path).exists() {
        std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .share_mode(0)
            .open(path)
            .map_err(|e| {
                format!("Close Flux and Windows Screen Saver Settings, then retry: {e}")
            })?;
    }
    Ok(())
}
#[cfg(feature = "test-hooks")]
fn receipt(file: &str) -> Result<(), String> {
    if file.is_empty() {
        return Ok(());
    }
    let previous = read(STATE, PREVIOUS)?;
    let original = if previous.is_some() {
        Some(text(&previous)?)
    } else {
        None
    };
    let data = serde_json::json!({"selection": encode(&read(DESKTOP, SELECTION)?), "previous": encode(&previous), "original": original});
    std::fs::write(file, data.to_string()).map_err(|e| e.to_string())
}
#[no_mangle]
pub extern "system" fn Prepare(handle: u32) -> u32 {
    run(handle, || {
        let sid = identity(handle)?;
        let folder = property(handle, "INSTALLFOLDER")?;
        if folder.contains('|') || !std::path::Path::new(&folder).is_absolute() {
            return Err("Invalid installation directory".into());
        }
        reject_reparse_ancestors(std::path::Path::new(&folder))?;
        #[cfg(all(not(feature = "test-hooks"), not(feature = "candidate-identity")))]
        {
            let expected = std::path::Path::new(&property(handle, "LocalAppDataFolder")?)
                .join("Flux")
                .join("MSI");
            if !same_path(
                folder.trim_end_matches(['\\', '/']),
                &expected.to_string_lossy(),
            ) {
                return Err("Use Flux's default per-user installation directory".into());
            }
        }
        let path = std::path::Path::new(&folder)
            .join("Flux.scr")
            .to_string_lossy()
            .into_owned();
        probe_binary(&path)?;
        let selected = read(DESKTOP, SELECTION)?;
        let previous = read(STATE, PREVIOUS)?;
        if previous.is_some() {
            decode(&text(&previous)?)?;
        }
        #[cfg(not(feature = "test-hooks"))]
        let report = String::new();
        #[cfg(feature = "test-hooks")]
        let report = property(handle, "FLUX_REPORT")?;
        set(
            handle,
            "RollbackSelection",
            &format!("{sid}|{}|{}|{report}", encode(&selected), encode(&previous)),
        )?;
        let removing = property(handle, "REMOVE")? == "ALL";
        let installed = !property(handle, "Installed")?.is_empty();
        let mut original = selected.clone();
        let legacy = property(handle, "LEGACYFOLDER")?;
        if legacy.contains('|') || !std::path::Path::new(&legacy).is_absolute() {
            return Err("Invalid legacy installation directory".into());
        }
        reject_reparse_ancestors(std::path::Path::new(&legacy))?;
        #[cfg(all(not(feature = "test-hooks"), not(feature = "candidate-identity")))]
        {
            let expected = std::path::Path::new(&property(handle, "LocalAppDataFolder")?)
                .join("Flux")
                .join("Screensaver");
            if !same_path(
                legacy.trim_end_matches(['\\', '/']),
                &expected.to_string_lossy(),
            ) {
                return Err("Only the default managed legacy installation can be migrated".into());
            }
        }
        let mut legacy_mode = "none";
        let mut legacy_command = String::new();
        if !removing
            && !same_path(&folder, &legacy)
            && std::path::Path::new(&legacy).join("Flux.scr").is_file()
        {
            let legacy_previous = legacy_original(&legacy)?;
            let legacy_binary = std::path::Path::new(&legacy)
                .join("Flux.scr")
                .to_string_lossy()
                .into_owned();
            probe_binary(&legacy_binary)?;
            if text(&selected).is_ok_and(|s| same_path(&s, &legacy_binary)) {
                original = legacy_previous;
            }
            if let Some(uninstaller) = legacy_uninstaller(handle, &legacy)? {
                legacy_command = uninstaller.clone();
                #[cfg(feature = "candidate-identity")]
                set(handle, "LEGACYUNINSTALLER", &uninstaller)?;
                legacy_mode = "inno";
            } else {
                // An unreadable registration must never turn an Inno installation into a ZIP.
                let entries = std::fs::read_dir(&legacy).map_err(|e| e.to_string())?;
                for entry in entries {
                    let name = entry
                        .map_err(|e| e.to_string())?
                        .file_name()
                        .to_string_lossy()
                        .to_ascii_lowercase();
                    if name.starts_with("unins")
                        && (name.ends_with(".exe") || name.ends_with(".dat"))
                    {
                        return Err("The legacy installer registration is unavailable. Uninstall the existing Flux installer through Windows Installed Apps, then retry; preferences are retained.".into());
                    }
                }
                legacy_mode = "zip";
            }
        }
        set(
            handle,
            "CommitLegacy",
            &format!("{sid}|{legacy_mode}|{legacy}|{legacy_command}|{path}"),
        )?;
        set(
            handle,
            if removing {
                "ChangeRemoval"
            } else {
                "ChangeSelection"
            },
            &format!(
                "{sid}|{}|{path}|{}",
                if removing {
                    "remove"
                } else if installed || previous.is_some() {
                    "repair"
                } else {
                    "install"
                },
                encode(&original)
            ),
        )
    })
}
#[no_mangle]
pub extern "system" fn Change(handle: u32) -> u32 {
    run(handle, || {
        let data = property(handle, "CustomActionData")?;
        let mut fields = data.split('|');
        let sid = fields.next().ok_or("Missing user SID")?;
        USER_SID.with(|s| *s.borrow_mut() = sid.into());
        let mode = fields.next().ok_or("Missing mode")?;
        let path = fields.next().ok_or("Missing screensaver path")?;
        let original = decode(fields.next().ok_or("Missing original selection")?)?;
        let previous = read(STATE, PREVIOUS)?;
        match mode {
            "remove" => {
                let selected = read(DESKTOP, SELECTION)?;
                if text(&selected).is_ok_and(|s| same_path(&s, path)) {
                    let restore = if previous.is_some() {
                        decode(&text(&previous)?)?
                    } else {
                        None
                    };
                    write(DESKTOP, SELECTION, &restore)?;
                }
                write(STATE, PREVIOUS, &None)?;
            }
            "install" => {
                if previous.is_none() {
                    write(STATE, PREVIOUS, &string(&encode(&original)))?;
                }
                write(DESKTOP, SELECTION, &string(path))?;
                if read(DESKTOP, SELECTION)? != string(path) {
                    return Err("Screensaver selection did not persist".into());
                }
            }
            "repair" => {}
            _ => return Err("Invalid action mode".into()),
        }
        log(handle, "Flux screensaver selection action completed");
        Ok(())
    })
}
#[no_mangle]
pub extern "system" fn Rollback(handle: u32) -> u32 {
    run(handle, || {
        let data = property(handle, "CustomActionData")?;
        let mut fields = data.split('|');
        USER_SID.with(|s| *s.borrow_mut() = fields.next().unwrap_or("").into());
        let selected = decode(fields.next().ok_or("Missing selection snapshot")?)?;
        let previous = decode(fields.next().ok_or("Missing metadata snapshot")?)?;
        write(DESKTOP, SELECTION, &selected)?;
        write(STATE, PREVIOUS, &previous)?;
        #[cfg(feature = "test-hooks")]
        {
            receipt(fields.next().unwrap_or(""))?;
        }
        Ok(())
    })
}
#[no_mangle]
pub extern "system" fn CommitLegacy(handle: u32) -> u32 {
    run(handle, || {
        let data = property(handle, "CustomActionData")?;
        let mut fields = data.split('|');
        USER_SID.with(|s| *s.borrow_mut() = fields.next().unwrap_or("").into());
        let mode = fields.next().ok_or("Missing migration mode")?;
        let folder = fields.next().ok_or("Missing legacy directory")?;
        #[cfg(not(feature = "candidate-identity"))]
        if mode == "inno" {
            use std::os::windows::{fs::OpenOptionsExt, process::CommandExt};
            let executable = fields.next().ok_or("Missing legacy uninstaller")?;
            let selected_path = fields.next().ok_or("Missing MSI screensaver path")?;
            reject_reparse_ancestors(std::path::Path::new(executable))?;
            // Keep the exact validated uninstaller immutable while it executes.
            let _guard = std::fs::OpenOptions::new()
                .read(true)
                .share_mode(1)
                .open(executable)
                .map_err(|e| e.to_string())?;
            let selection = read(DESKTOP, SELECTION)?;
            let mut process = std::process::Command::new(executable)
                .args(["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"])
                .creation_flags(0x08000000)
                .spawn()
                .map_err(|e| e.to_string())?;
            drop(_guard); // Inno must be able to remove its own original uninstaller.
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(120);
            loop {
                if let Some(status) = process.try_wait().map_err(|e| e.to_string())? {
                    if !status.success() {
                        return Err("Flux MSI is installed, but the previous installer's removal failed. Remove the old entry through Windows Installed Apps.".into());
                    }
                    break;
                }
                if std::time::Instant::now() >= deadline {
                    return Err("Flux MSI is installed, but legacy removal has not completed; no process was terminated.".into());
                }
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
            // An Inno registry uninstall must not erase the newly selected saver.
            if text(&selection).is_ok_and(|s| same_path(&s, selected_path))
                && read(DESKTOP, SELECTION)?.is_none()
            {
                write(DESKTOP, SELECTION, &selection)?;
            }
            if std::path::Path::new(folder).join("Flux.scr").exists() {
                return Err("The old Flux payload remains after migration. The new MSI installation is retained.".into());
            }
            log(
                handle,
                "Flux legacy Inno migration completed after MSI commit",
            );
            return Ok(());
        }
        if mode != "zip" {
            return Ok(());
        }
        // Only a valid, managed legacy package is eligible. Never recurse or delete preferences.
        reject_reparse_ancestors(std::path::Path::new(folder))?;
        legacy_original(folder)?;
        let binary = std::path::Path::new(folder)
            .join("Flux.scr")
            .to_string_lossy()
            .into_owned();
        probe_binary(&binary)?;
        for name in [
            "Flux.scr",
            "LICENSE",
            "deployment.ps1",
            "Install.ps1",
            "Install.cmd",
            "Uninstall.ps1",
            "Uninstall.cmd",
            "installation.json",
            "Flux.log",
        ] {
            let file = std::path::Path::new(folder).join(name);
            reject_reparse_ancestors(&file)?;
            if file.is_file() {
                std::fs::remove_file(file).map_err(|e| e.to_string())?;
            }
        }
        // This removes only an empty directory. Unknown files are preserved.
        match std::fs::remove_dir(folder) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::DirectoryNotEmpty => {}
            Err(e) => return Err(e.to_string()),
        }
        log(handle, "Flux managed ZIP installation migration completed");
        Ok(())
    })
}
#[cfg(feature = "test-hooks")]
#[no_mangle]
pub extern "system" fn TestSeed(handle: u32) -> u32 {
    run(handle, || {
        identity(handle)?;
        let value = property(handle, "FLUX_TEST_SELECTION")?;
        if !value.is_empty() {
            write(DESKTOP, SELECTION, &decode(&value)?)?;
        }
        Ok(())
    })
}
#[cfg(feature = "test-hooks")]
#[no_mangle]
pub extern "system" fn TestVerify(handle: u32) -> u32 {
    run(handle, || {
        identity(handle)?;
        receipt(&property(handle, "FLUX_REPORT")?)?;
        let restore = property(handle, "FLUX_TEST_RESTORE")?;
        if !restore.is_empty() {
            write(DESKTOP, SELECTION, &decode(&restore)?)?;
            let file = property(handle, "FLUX_REPORT")?;
            if !file.is_empty() {
                let mut report: serde_json::Value =
                    serde_json::from_slice(&std::fs::read(&file).map_err(|e| e.to_string())?)
                        .map_err(|e| e.to_string())?;
                report["postRestore"] = encode(&read(DESKTOP, SELECTION)?).into();
                std::fs::write(file, report.to_string()).map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    })
}
#[cfg(feature = "test-hooks")]
#[no_mangle]
pub extern "system" fn FailForTest(_: u32) -> u32 {
    1603
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn snapshots_preserve_absence_and_arbitrary_type_bytes() {
        for value in [
            None,
            Some((1, vec![65, 0, 0, 0])),
            Some((3, vec![0, 255, 42])),
            Some((4, vec![1, 0, 0, 0])),
        ] {
            assert_eq!(decode(&encode(&value)).unwrap(), value);
        }
    }
    #[test]
    fn corrupt_snapshots_fail_without_registry_calls() {
        for value in ["", "1", "1:f", "bad:00", "1:zz", "1:é0"] {
            assert!(decode(value).is_err(), "{value}");
        }
    }
    #[test]
    fn string_values_require_valid_utf16_and_string_kind() {
        assert_eq!(text(&string("Flux 🖥")).unwrap(), "Flux 🖥");
        for value in [
            None,
            Some((3, vec![65, 0])),
            Some((1, vec![65])),
            Some((1, vec![0, 216])),
        ] {
            assert!(text(&value).is_err());
        }
    }
    #[test]
    fn ownership_path_comparison_does_not_match_other_savers() {
        assert!(same_path(
            "\"C:/User/Flux/Flux.scr\"",
            "c:\\user\\flux\\flux.scr"
        ));
        assert!(!same_path(
            "C:/User/Flux/Flux.scr",
            "C:/User/Flux2/Flux.scr"
        ));
        assert!(!same_path(
            "C:/User/Flux/Flux.scr",
            "C:/User/Flux/Flux.scr.exe"
        ));
    }
}
