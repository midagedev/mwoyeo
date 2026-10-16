#!/bin/zsh
# Prints the Homebrew cask for a release: scripts/cask.sh <version> <sha256 of the dmg>
set -euo pipefail
cat <<CASK
cask "mwoyeo" do
  version "${1:?version}"
  sha256 "${2:?sha256}"

  url "https://github.com/midagedev/mwoyeo/releases/download/v#{version}/Mwoyeo-#{version}-arm64.dmg"
  name "Mwoyeo"
  desc "Live, in-place screen translation"
  homepage "https://github.com/midagedev/mwoyeo"

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Mwoyeo.app"

  zap trash: "~/Library/Preferences/dev.midagedev.mwoyeo.plist"

  caveats <<~EOS
    Mwoyeo needs macOS 26 and Screen Recording permission (asked on first launch).
    The first text recognition after launch can take up to a minute while the model loads.
  EOS
end
CASK
