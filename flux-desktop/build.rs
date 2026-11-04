fn main() {
    println!("cargo:rerun-if-changed=flux.rc");
    println!("cargo:rerun-if-changed=../packaging/windows/Flux.ico");

    // Embed the icon so Explorer shows it for Flux.exe and the copied Flux.scr.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        embed_resource::compile("flux.rc", embed_resource::NONE)
            .manifest_optional()
            .expect("failed to embed the Flux icon resource");
    }
}
