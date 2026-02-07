fn main() {
    slint_build::compile("src/generated/app.slint")
        .expect("failed to compile app.slint");
    println!("cargo:rerun-if-changed=src/generated/app.slint");
    println!("cargo:rerun-if-changed=src/generated/screen_host.slint");
    println!("cargo:rerun-if-changed=src/generated/routes.slint");
    println!("cargo:rerun-if-changed=../../lib/projection_ui/ui/app_shell.slint");
    println!("cargo:rerun-if-changed=../../lib/projection_ui/ui/clock.slint");
    println!("cargo:rerun-if-changed=../../lib/projection_ui/ui/devices.slint");
    println!("cargo:rerun-if-changed=../../lib/projection_ui/ui/error.slint");
}
