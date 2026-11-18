---
layout: default
title: Install IssueLight
description: Install the current signed IssueLight release or build it from source on macOS.
---

<section class="page-hero shell">
  <p class="eyebrow"><span></span>Install IssueLight</p>
  <h1>Monitor infrastructure from the macOS menu bar.</h1>
  <p>Direct releases are published for macOS 14 and later. The direct edition is Developer ID signed, notarized and keeps its signed Sparkle update feed. The App Store edition will use Apple's update channel when it becomes available.</p>
</section>

<section class="steps shell">
  <article><span>01</span><div><h2>Download the latest release</h2><p>Open the latest GitHub release, download the universal DMG or ZIP and move IssueLight to Applications. Gatekeeper verifies the notarized direct build when you first open it.</p></div></article>
  <article><span>02</span><div><h2>Connect a monitoring source</h2><p>Open IssueLight from the menu bar and add an Icinga 2, Thruk, Checkmk or Nagios Core source. Credentials stay in your macOS Keychain.</p></div></article>
  <article><span>03</span><div><h2>Build from source when contributing</h2><pre><code>git clone https://github.com/YunaBraska/issuelight.git
cd issuelight
xcodegen generate --spec IssueLight/project.yml</code></pre></div></article>
  <article><span>04</span><div><h2>Run the verified local checks</h2><pre><code>swift test --package-path Packages/IssueLightCore
xcodebuild test \
  -project IssueLight/IssueLight.xcodeproj \
  -scheme IssueLight \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO</code></pre></div></article>
  <article><span>05</span><div><h2>Open the native app</h2><p>Open <code>IssueLight/IssueLight.xcodeproj</code> in Xcode and run the <code>IssueLight</code> scheme. A development build is not a notarized distribution package.</p></div></article>
</section>

<section class="callout shell">
  <div><strong>Use the signed direct edition</strong><p>New direct releases publish a signed Sparkle update feed. Existing installations ask before they install an update.</p></div>
  <a class="button" href="{{ site.releases }}">Download latest release</a>
</section>
