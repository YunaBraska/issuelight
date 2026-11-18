---
layout: default
title: Attention-first infrastructure monitoring
description: IssueLight keeps infrastructure problems in the macOS menu bar and stays quiet when everything is healthy.
---

<section class="hero shell">
  <div class="hero-copy">
    <p class="eyebrow"><span></span>Icinga 2, Thruk, Checkmk and Nagios Core, without the dashboard detour</p>
    <h1>See what needs you. Ignore the rest.</h1>
    <p class="lead">IssueLight turns monitoring state into a small, native macOS signal. Healthy systems stay out of the way. Problems arrive ordered by attention, across every source you configured.</p>
    <div class="actions">
      <a class="button" href="{{ '/install.html' | relative_url }}">Build IssueLight</a>
      <a class="button secondary" href="{{ site.repository }}">View the source</a>
    </div>
    <p class="release-note"><span>Open-source preview</span> macOS 14+ · Icinga 2 baseline · Thruk, Checkmk and Nagios Core supported</p>
  </div>
  <figure class="hero-shot app-window">
    <div class="window-bar"><span></span><span></span><span></span><strong>Menu bar status</strong></div>
    <img src="{{ '/assets/screenshots/menu-panel-all-providers.png' | relative_url }}" alt="IssueLight menu panel with Icinga, Checkmk, Thruk and Nagios problems" width="1440" height="410">
    <figcaption>Four providers, one compact queue, and only the actions each provider actually supports.</figcaption>
  </figure>
</section>

<section class="statement-band">
  <div class="shell statement">
    <p class="eyebrow"><span></span>The premise</p>
    <h2>Monitoring should interrupt you only when it earns the interruption.</h2>
  </div>
</section>
<section class="section shell">
  <div class="section-heading">
    <p class="eyebrow"><span></span>Daily use</p>
    <h2>Small surface. Deliberate signal.</h2>
    <p>IssueLight is not a second Icinga dashboard. It is the quick check before you decide whether a dashboard is needed.</p>
  </div>
  <div class="principles">
    <article><span class="principle-number">01</span><h3>Quiet is a valid state</h3><p>The menu bar shows a calm success state when no host or service needs attention. No window demands to remain open.</p></article>
    <article><span class="principle-number">02</span><h3>Attention has an order</h3><p>Critical, unknown and warning states stay distinct. Acknowledged issues and downtime remain visible without competing with active problems.</p></article>
    <article><span class="principle-number">03</span><h3>Sources stay independent</h3><p>Production, staging and a homelab can refresh separately. A failed source keeps its last known snapshot and does not erase healthy data from another.</p></article>
  </div>
</section>

<section class="section shell security-section">
  <div class="security-copy">
    <p class="eyebrow"><span></span>Quiet notifications</p>
    <h2>New signal, not recurring noise.</h2>
    <p>Notifications are off until you enable a policy for a source. Existing problems establish a silent baseline. Only a new or escalated problem earns a banner.</p>
    <ul class="check-list">
      <li><strong>Per source</strong><span>Choose critical, warning and critical, or every attention state.</span></li>
      <li><strong>Deduplicated</strong><span>Unchanged problems never repeat. Full recovery removes the source summary.</span></li>
      <li><strong>Private banner</strong><span>No source, host, service, output, credential or infrastructure URL is shown.</span></li>
      <li><strong>Same navigation</strong><span>A click uses the provider web target and its direct-first SSH fallback.</span></li>
    </ul>
  </div>
  <figure class="app-window">
    <div class="window-bar"><span></span><span></span><span></span><strong>Notification settings</strong></div>
    <img src="{{ '/assets/screenshots/settings-notifications.png' | relative_url }}" alt="IssueLight notification settings with macOS access and a severity policy for each source" width="1520" height="1120">
  </figure>
</section>

<section class="section shell language-section">
  <div class="section-heading">
    <p class="eyebrow"><span></span>Your language, without a restart</p>
    <h2>System default or an explicit language.</h2>
    <p>Choose one of 21 built-in languages in Settings. Arabic and Urdu switch the complete interface to a right-to-left layout.</p>
  </div>
  <div class="language-grid">
    <figure class="app-window language-states">
      <img src="{{ '/assets/screenshots/menu-item-states.png' | relative_url }}" alt="IssueLight custom lighthouse menu bar signal in setup, paused, refreshing, healthy, failed and seven-problem states" width="1320" height="360">
      <figcaption>One custom lighthouse signal covers setup, paused, refreshing, healthy, failed and attention states.</figcaption>
    </figure>
    <figure class="app-window">
      <img src="{{ '/assets/screenshots/menu-panel-sv.png' | relative_url }}" alt="IssueLight status menu in Swedish" width="860" height="480">
      <figcaption>Swedish menu panel</figcaption>
    </figure>
    <figure class="app-window">
      <img src="{{ '/assets/screenshots/menu-panel-ar.png' | relative_url }}" alt="IssueLight status menu in Arabic with right-to-left layout" width="860" height="480">
      <figcaption>Arabic right-to-left menu panel</figcaption>
    </figure>
  </div>
</section>

<section class="section shell security-section">
  <figure class="setup-shot app-window">
    <div class="window-bar"><span></span><span></span><span></span><strong>Source settings</strong></div>
    <img src="{{ '/assets/screenshots/source-setup.png' | relative_url }}" alt="IssueLight source settings with an Icinga 2 source" width="1640" height="1200">
  </figure>
  <div class="security-copy">
    <p class="eyebrow"><span></span>Secure by default</p>
    <h2>Real infrastructure deserves real trust controls.</h2>
    <p>Credentials belong in macOS Keychain. Certificate verification stays enabled unless you make a source-specific exception.</p>
    <ul class="check-list">
      <li><strong>Authentication</strong><span>Basic credentials, provider API keys or a selected client certificate.</span></li>
      <li><strong>Server trust</strong><span>macOS system trust, a private CA or an exact server-certificate pin.</span></li>
      <li><strong>Homelab escape hatch</strong><span>Certificate verification can be disabled per source, with an explicit warning.</span></li>
      <li><strong>No secret config files</strong><span>Source records keep references. Passwords, API keys and private keys stay in Keychain.</span></li>
    </ul>
  </div>
</section>

<section class="section shell provider-section">
  <div class="section-heading">
    <p class="eyebrow"><span></span>Provider-aware setup</p>
    <h2>One flow. The right fields for each system.</h2>
    <p>Choose the provider explicitly, then give IssueLight as little as possible. Endpoint normalization, API discovery and provider-specific authentication fill in the rest.</p>
  </div>
  <div class="provider-grid">
    <figure class="app-window">
      <div class="provider-shot"><img src="{{ '/assets/screenshots/source-setup.png' | relative_url }}" alt="Icinga 2 source setup with username and password authentication" width="1640" height="1200"></div>
      <figcaption>Icinga 2 · Basic authentication or client certificate</figcaption>
    </figure>
    <figure class="app-window">
      <div class="provider-shot"><img src="{{ '/assets/screenshots/source-setup-thruk.png' | relative_url }}" alt="Thruk source setup with provider-specific API authentication" width="1640" height="1200"></div>
      <figcaption>Thruk · Basic authentication or API key</figcaption>
    </figure>
    <figure class="app-window">
      <div class="provider-shot"><img src="{{ '/assets/screenshots/source-setup-checkmk.png' | relative_url }}" alt="Checkmk source setup with automation user and API key" width="1640" height="1200"></div>
      <figcaption>Checkmk · Automation user and API key</figcaption>
    </figure>
    <figure class="app-window">
      <div class="provider-shot"><img src="{{ '/assets/screenshots/source-setup-nagios-core.png' | relative_url }}" alt="Nagios Core source setup with username and password authentication" width="1640" height="1200"></div>
      <figcaption>Nagios Core · Status JSON and command CGI</figcaption>
    </figure>
  </div>
</section>

<section class="section shell settings-tour">
  <div class="section-heading">
    <p class="eyebrow"><span></span>Native macOS settings</p>
    <h2>Sources, notifications, language and About. No duplicate controls.</h2>
    <p>The single Settings button opens a resizable native window. Every preference stays in one predictable place. <a href="{{ '/review.html' | relative_url }}">Review every meaningful UI state.</a></p>
  </div>
  <div class="settings-grid">
    <figure class="app-window">
      <img src="{{ '/assets/screenshots/settings-notifications-window.png' | relative_url }}" alt="Resizable IssueLight settings window on the Notifications tab" width="2292" height="1612">
      <figcaption>Quiet notification policies remain opt-in per source.</figcaption>
    </figure>
    <figure class="app-window">
      <img src="{{ '/assets/screenshots/settings-language-window.png' | relative_url }}" alt="Resizable IssueLight settings window on the Language tab" width="2292" height="1612">
      <figcaption>System default and 21 explicit languages are available without restarting.</figcaption>
    </figure>
    <figure class="app-window">
      <img src="{{ '/assets/screenshots/settings-about-window.png' | relative_url }}" alt="Resizable IssueLight settings window on the About IssueLight tab" width="2292" height="1612">
      <figcaption>Updates, privacy, support and project credits live in About.</figcaption>
    </figure>
  </div>
</section>

<section class="evidence-band">
  <div class="shell evidence-layout">
    <div>
      <p class="eyebrow"><span></span>Tested against the thing itself</p>
      <h2>Real monitoring systems, not optimistic JSON fixtures.</h2>
    </div>
    <div class="matrix" role="list" aria-label="Real-system integration coverage">
      <span role="listitem">HTTP</span>
      <span role="listitem">HTTPS</span>
      <span role="listitem">Basic auth</span>
      <span role="listitem">mTLS</span>
      <span role="listitem">Private CA</span>
      <span role="listitem">Exact pinning</span>
      <span role="listitem">Rejected auth</span>
      <span role="listitem">Rejected trust</span>
      <span role="listitem">Thruk 3.30</span>
      <span role="listitem">Naemon</span>
      <span role="listitem">API-key commands</span>
      <span role="listitem">Checkmk 2.5</span>
      <span role="listitem">Nagios Core 4.5</span>
      <span role="listitem">Command CGI CSRF</span>
    </div>
    <p class="evidence-note">The pinned Icinga, OMD Labs and Checkmk containers plus a source-built Nagios Core drive the same public provider paths used by the app. Unit tests cover deterministic domain behavior. The screenshot test renders the production SwiftUI views shown on this page.</p>
  </div>
</section>

<section class="section shell scope-section">
  <div class="section-heading">
    <p class="eyebrow"><span></span>Scope you can reason about</p>
    <h2>Icinga 2 baseline. Four systems through one boundary.</h2>
    <p>Icinga 2 is the current compatibility baseline. Thruk, Checkmk and Nagios Core cross the same provider boundary and are verified against pinned official releases. Provider capabilities decide which commands are available.</p>
  </div>
  <div class="scope-grid">
    <div><strong>Available now</strong><p>Multiple sources, refresh, attention ordering, quiet notifications, strict TLS options, Keychain credentials, recheck, acknowledgement, fixed downtime and stale-state retention.</p></div>
    <div><strong>Still required</strong><p>The final application check is an installed-app test with a genuinely user-protected mTLS private key.</p></div>
    <div><strong>Release status</strong><p>The app and unsigned packaging path are tested. Signing, notarization and store delivery belong to the shared CI/CD release flow.</p></div>
  </div>
</section>

<section class="closing-band">
  <div class="shell closing-content">
    <img src="{{ '/assets/app-icon.png' | relative_url }}" alt="IssueLight lighthouse app icon" width="148" height="148">
    <div><p class="eyebrow"><span></span>Apache-2.0 open source</p><h2>Inspect it. Test it. Make the signal better.</h2><p>IssueLight is developed in public with its specifications, architecture decisions, real integration lab and release evidence in the repository.</p></div>
    <div class="actions"><a class="button" href="{{ site.repository }}">Open GitHub</a><a class="button secondary" href="{{ '/documentation.html' | relative_url }}">Read the docs</a></div>
  </div>
</section>
