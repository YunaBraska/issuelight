---
layout: default
title: Build IssueLight
description: Build and run the current IssueLight source on macOS.
---

<section class="page-hero shell">
  <p class="eyebrow"><span></span>Current distribution</p>
  <h1>Build it from source today.</h1>
  <p>IssueLight does not have a notarized public download yet. The repository is usable for development and evaluation, while the release remains explicitly pre-production.</p>
</section>

<section class="steps shell">
  <article><span>01</span><div><h2>Install the toolchain</h2><p>Use macOS 14 or newer, Xcode 16 or newer and XcodeGen 2.45 or newer.</p></div></article>
  <article><span>02</span><div><h2>Clone and generate the project</h2><pre><code>git clone https://github.com/YunaBraska/issuelight.git
cd issuelight
xcodegen generate --spec IssueLight/project.yml</code></pre></div></article>
  <article><span>03</span><div><h2>Run the verified local checks</h2><pre><code>swift test --package-path Packages/IssueLightCore
xcodebuild test \
  -project IssueLight/IssueLight.xcodeproj \
  -scheme IssueLight \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO</code></pre></div></article>
  <article><span>04</span><div><h2>Open the native app</h2><p>Open <code>IssueLight/IssueLight.xcodeproj</code> in Xcode and run the <code>IssueLight</code> scheme. A development build is not a notarized distribution package.</p></div></article>
</section>

<section class="callout shell">
  <div><strong>Waiting for the signed release?</strong><p>Watch the repository's release page. IssueLight will not call an unsigned archive “production-ready” to make the button look more exciting.</p></div>
  <a class="button" href="{{ site.releases }}">View releases</a>
</section>
