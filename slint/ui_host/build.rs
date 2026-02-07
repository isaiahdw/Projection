fn main() {
    slint_build::compile("../../lib/projection_ui/screens/app.slint")
        .expect("failed to compile app.slint");
    println!("cargo:rerun-if-changed=../../lib/projection_ui/screens/app.slint");
    println!("cargo:rerun-if-changed=src/generated/routes.slint");
    println!("cargo:rerun-if-changed=../../lib/projection_ui/screens/layouts/app_shell.slint");
    println!("cargo:rerun-if-changed=../../lib/projection_ui/screens/templates/clock.slint");
    println!("cargo:rerun-if-changed=../../lib/projection_ui/screens/templates/devices.slint");
}
