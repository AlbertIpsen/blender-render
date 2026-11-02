#!/usr/bin/env bash
# Build BlenderRenderPC.exe (the Windows tray app) into ../pc/, where build_app.sh bundles it.
# Needs the .NET SDK (installed in ~/.dotnet: https://dot.net/v1/dotnet-install.sh --channel 8.0).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
"$DOTNET" build "$HERE/BlenderRenderPC.csproj" -c Release -o "$HERE/bin/out" -v quiet -nologo
cp "$HERE/bin/out/BlenderRenderPC.exe" "$HERE/../pc/BlenderRenderPC.exe"
echo "built pc/BlenderRenderPC.exe"
