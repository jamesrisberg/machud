#!/bin/zsh
# The voice host ships as Contents/Helpers/MacHUDVoice; MacHUD runs it as its child.
cd "${0:A:h}" && HUD_HELPERS=MacHUDVoice exec "${HUDKIT_DIR:-../hudkit}/scripts/hud-build.sh" MacHUD "$@"
