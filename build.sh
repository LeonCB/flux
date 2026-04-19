#!/bin/bash
set -e

# Cross-compile script for Flux screensaver (Windows 64-bit) on Debian/Linux
# Builds a Windows x86_64 executable from Linux using MinGW-w64

TARGET="x86_64-pc-windows-gnu"

echo "Installing build dependencies..."
sudo apt-get update
sudo apt-get install -y \
    mingw-w64 \
    mingw-w64-tools \
    mingw-w64-x86-64-dev

echo ""
echo "Setting up Rust target for Windows..."
rustup target add $TARGET

echo ""
echo "Building flux-desktop for Windows (x86_64)..."
cargo build --release --package flux-desktop --target $TARGET

if [ $? -ne 0 ]; then
    echo "Build failed."
    exit 1
fi

echo ""
echo "Copying executable to flux.scr..."
cp "target/$TARGET/release/flux-desktop.exe" "flux.scr"

if [ $? -ne 0 ]; then
    echo "Copy failed."
    exit 1
fi

echo ""
echo "Success! flux.scr (Windows x86_64) has been created."
