cask "macssential" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/LuxuryCarrot/macssential/releases/download/v#{version}/macssential-#{version}.dmg"
  name "macssential"
  desc "Menu bar toolbox that tames macOS defaults for switchers"
  homepage "https://github.com/LuxuryCarrot/macssential"

  depends_on macos: :sonoma
  app "macssential.app"

  zap trash: [
    "~/Library/Preferences/com.macssential.macssential.plist",
    "~/Library/Caches/com.macssential.macssential",
  ]
end
