---
layout: default
title: UI review gallery
description: Production-rendered IssueLight states for visual review.
---

<section class="section shell">
  <div class="section-heading">
    <p class="eyebrow"><span></span>UI review gallery</p>
    <h1>Normal, empty, failure and configuration states.</h1>
    <p>These images are generated from IssueLight's production SwiftUI views. They cover the states that materially change layout, hierarchy or available actions.</p>
  </div>
</section>

<section class="section shell settings-tour">
  <div class="section-heading">
    <h2>Menu bar and problem panel</h2>
    <p>The menu bar uses the lighthouse only when no issue counter is available. Active problems use counters alone.</p>
  </div>
  <div class="settings-grid">
    <figure class="app-window"><img src="{{ '/assets/screenshots/menu-item-states.png' | relative_url }}" alt="IssueLight menu bar states" width="1320" height="360"><figcaption>Setup, pause, refresh, all clear, failure and active counters</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/menu-panel-all-providers.png' | relative_url }}" alt="Problems from all supported providers" width="1440" height="410"><figcaption>Icinga 2, Checkmk, Thruk and Nagios Core</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/menu-panel-dark-large-text.png' | relative_url }}" alt="Dark IssueLight problem panel with larger text" width="1440" height="450"><figcaption>Dark appearance with larger text</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/menu-panel-no-source.png' | relative_url }}" alt="No monitoring source configured" width="1440" height="440"><figcaption>No source configured</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/menu-panel-disabled-source.png' | relative_url }}" alt="All monitoring sources paused" width="1440" height="440"><figcaption>All sources paused</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/menu-panel-loading.png' | relative_url }}" alt="Monitoring status loading" width="1440" height="440"><figcaption>Initial load</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/menu-panel-all-clear.png' | relative_url }}" alt="All monitored systems clear" width="1440" height="400"><figcaption>All clear</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/menu-panel-filtered-empty.png' | relative_url }}" alt="No monitoring issues match active filters" width="1440" height="400"><figcaption>Active filter with no matches</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/menu-panel-source-failure.png' | relative_url }}" alt="Monitoring source unavailable" width="1440" height="176"><figcaption>Source unavailable</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/menu-panel-action-error.png' | relative_url }}" alt="Monitoring action rejected by the server" width="1440" height="264"><figcaption>Action rejected without hiding the issue</figcaption></figure>
  </div>
</section>

<section class="section shell provider-section">
  <div class="section-heading">
    <h2>Provider-aware source setup</h2>
    <p>The provider selector keeps one setup journey while exposing only supported authentication and actions.</p>
  </div>
  <div class="provider-grid">
    <figure class="app-window"><div class="provider-shot"><img src="{{ '/assets/screenshots/source-setup.png' | relative_url }}" alt="Icinga 2 source setup" width="1640" height="1200"></div><figcaption>Icinga 2</figcaption></figure>
    <figure class="app-window"><div class="provider-shot"><img src="{{ '/assets/screenshots/source-setup-thruk.png' | relative_url }}" alt="Thruk source setup" width="1640" height="1200"></div><figcaption>Thruk</figcaption></figure>
    <figure class="app-window"><div class="provider-shot"><img src="{{ '/assets/screenshots/source-setup-checkmk.png' | relative_url }}" alt="Checkmk source setup" width="1640" height="1200"></div><figcaption>Checkmk</figcaption></figure>
    <figure class="app-window"><div class="provider-shot"><img src="{{ '/assets/screenshots/source-setup-nagios-core.png' | relative_url }}" alt="Nagios Core source setup" width="1640" height="1200"></div><figcaption>Nagios Core</figcaption></figure>
  </div>
</section>

<section class="section shell settings-tour">
  <div class="section-heading">
    <h2>Security and reachability combinations</h2>
    <p>API and web reachability are independent. Direct access, SSH fallback and failures remain visible separately.</p>
  </div>
  <div class="settings-grid">
    <figure class="app-window language-states"><img src="{{ '/assets/screenshots/connection-path-combinations.png' | relative_url }}" alt="API and web reachability combinations" width="1640" height="1000"><figcaption>Direct, SSH and unavailable combinations</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/source-setup-mtls-pinned.png' | relative_url }}" alt="Icinga source with client certificate authentication and exact server certificate pinning" width="1800" height="2400"><figcaption>Client certificate and exact server pin</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/source-setup-insecure-ssh.png' | relative_url }}" alt="Homelab source with disabled certificate validation and expanded SSH settings" width="1800" height="3000"><figcaption>Source-specific insecure TLS exception with SSH overrides</figcaption></figure>
  </div>
</section>

<section class="section shell settings-tour">
  <div class="section-heading">
    <h2>Settings and localization</h2>
    <p>The window is resizable. Arabic and Urdu use right-to-left layout, while every language can override the macOS default without restarting.</p>
  </div>
  <div class="settings-grid">
    <figure class="app-window"><img src="{{ '/assets/screenshots/settings-notifications-window.png' | relative_url }}" alt="Notification settings" width="2292" height="1612"><figcaption>Notification policies</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/settings-language-window.png' | relative_url }}" alt="Language settings" width="2292" height="1612"><figcaption>Language override</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/settings-about-window.png' | relative_url }}" alt="About IssueLight settings" width="2292" height="1612"><figcaption>About, support and update links</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/menu-panel-sv.png' | relative_url }}" alt="Swedish problem panel" width="1440" height="254"><figcaption>Swedish</figcaption></figure>
    <figure class="app-window"><img src="{{ '/assets/screenshots/menu-panel-ar.png' | relative_url }}" alt="Arabic right-to-left problem panel" width="1440" height="254"><figcaption>Arabic right-to-left</figcaption></figure>
  </div>
</section>
