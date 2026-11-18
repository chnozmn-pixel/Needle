cask "needle" do
  version "0.1.0"
  sha256 "df7fd5cf9ac7db954ff9523e4927534c6ea7b414aa043ad8bfdc5dfb0b05e250"

  url "https://github.com/OWNER/Needle/releases/download/v#{version}/Needle-#{version}.zip",
      verified: "github.com/OWNER/Needle/"
  name "Needle"
  desc "Fast local file search for macOS inspired by Everything"
  homepage "https://github.com/OWNER/Needle"

  app "Needle.app"

  zap trash: [
    "~/Library/Application Support/Needle",
    "~/Library/Preferences/com.local.needle.plist",
    "~/Library/Saved Application State/com.local.needle.savedState",
  ]
end
