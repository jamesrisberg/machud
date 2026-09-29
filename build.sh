#!/bin/zsh
# Helpers in Contents/Helpers: MacHUDVoice (the voice host, MacHUD's child process) and
# machud-mcp (MacHUD's MCP tool server, which the voice host hands to its brain).
cd "${0:A:h}" && HUD_HELPERS="MacHUDVoice machud-mcp" exec "${HUDKIT_DIR:-../hudkit}/scripts/hud-build.sh" MacHUD "$@"
