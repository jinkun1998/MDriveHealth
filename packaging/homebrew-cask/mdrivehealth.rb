# Homebrew cask DRAFT for MDriveHealth.
# Submit to a tap (e.g. maclife-cloud/homebrew-tap) once a public GitHub
# release exists:  brew tap maclife-cloud/tap && brew install --cask mdrivehealth
# Update `version` + `sha256` per release (livecheck automates detection).
cask "mdrivehealth" do
  version "0.1.0"
  sha256 :no_check # TODO: pin the DMG's sha256 per release

  url "https://github.com/maclife-cloud/MDriveHealth/releases/download/v#{version}/MDriveHealth-#{version}.dmg"
  name "MDriveHealth"
  desc "Drive & system health monitor with SMART, benchmark, and fake-capacity check"
  homepage "https://github.com/maclife-cloud/MDriveHealth"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "MDriveHealth.app"

  zap trash: [
    "~/Library/Application Support/MDriveHealth",
    "~/Library/Preferences/com.maclife.MDriveHealth.plist",
  ]
end
