#!/bin/sh
set -e

# Builds the test place and runs the given server script inside it. This is
# the bootstrap that test entry points share.

# If DevPackages aren't installed, install them.
if [ ! -d "DevPackages" ]; then
    wally install
fi
rojo build test.project.json --output GlassmorphicUITest.rbxl
run-in-roblox --place GlassmorphicUITest.rbxl --script "$1"
