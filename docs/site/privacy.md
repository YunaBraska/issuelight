---
layout: default
title: Privacy
description: How IssueLight handles monitoring data, credentials and local configuration.
---

<section class="page-hero shell">
  <p class="eyebrow"><span></span>Privacy</p>
  <h1>Your monitoring data stays between your Mac and your sources.</h1>
  <p>IssueLight has no account, advertising, analytics, crash-reporting SDK or hosted relay service.</p>
</section>

<section class="privacy-grid shell">
  <article><h2>Network</h2><p>The app reads host and service state directly from configured Icinga 2 sources. Operator-initiated recheck, acknowledgement and downtime commands return to the same source under its selected TLS policy.</p></article>
  <article><h2>Credentials</h2><p>Passwords and selected client identities stay in macOS Keychain. Source configuration stores references instead of secret values or private keys.</p></article>
  <article><h2>Local state</h2><p>Names, endpoints, public certificate fingerprints, and optional web or remote-access settings are stored in the user's Application Support directory. A selected SSH identity is stored as a file path, never as copied key material. Monitoring snapshots remain in memory and are not persisted by IssueLight.</p></article>
  <article><h2>Diagnostics</h2><p>IssueLight does not upload diagnostics. Remove private infrastructure names, payloads, credentials and certificates before sharing an issue report.</p></article>
</section>

<section class="callout shell">
  <div><strong>Complete privacy boundary</strong><p>The repository document includes exact storage paths, deletion behavior and the warning attached to disabled certificate verification.</p></div>
  <a class="button" href="{{ site.repository }}/blob/main/PRIVACY.md">Read PRIVACY.md</a>
</section>
