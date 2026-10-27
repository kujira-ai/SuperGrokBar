class SupergrokBar < Formula
  desc "macOS menu bar monitor for Grok Bot and Grok Build usage"
  homepage "https://github.com/kujira-ai/SuperGrokBar"
  url "https://github.com/kujira-ai/SuperGrokBar/archive/refs/tags/v1.2.6.tar.gz"
  sha256 "56b8ad863740428f2d2857613b7a2b0e9d60f3237f46037e4f9146d78dc6355c"
  license "MIT"
  head "https://github.com/kujira-ai/SuperGrokBar.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "SuperGrokBar"
    bin_path = Utils.safe_popen_read("swift", "build", "-c", "release", "--show-bin-path").strip

    libexec.install "#{bin_path}/SuperGrokBar"
    resource_bundle = "#{bin_path}/SuperGrokBar_SuperGrokBar.bundle"
    libexec.install resource_bundle if File.directory?(resource_bundle)

    # CLI that builds ~/Applications/SuperGrokBar.app + LaunchAgent
    (bin/"supergrok-bar").write <<~SH
      #!/bin/bash
      export SUPERGROK_BAR_EXEC="#{libexec}/SuperGrokBar"
      exec "#{prefix}/share/supergrok-bar/supergrok-bar" "$@"
    SH
    chmod 0755, bin/"supergrok-bar"

    (share/"supergrok-bar").install "Scripts/supergrok-bar"
    chmod 0755, share/"supergrok-bar/supergrok-bar"
  end

  def caveats
    <<~EOS
      Requires a Grok CLI session (`grok login`) for Build credits.
      Grok Bot weekly usage is read from the Grok Bot or Cursor.app session.

      Start the menu bar app (also sets Launch-at-Login agent):
        supergrok-bar

      Remove the app + LaunchAgent (formula stays installed):
        supergrok-bar uninstall
    EOS
  end

  test do
    assert_predicate libexec/"SuperGrokBar", :exist?
    assert_match "1.2.6", shell_output("#{bin}/supergrok-bar version")
  end
end
