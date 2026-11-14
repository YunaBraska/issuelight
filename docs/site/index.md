---
layout: default
title: Attention-first Icinga monitoring
description: IssueLight keeps Icinga 2 problems in the macOS menu bar and stays quiet when everything is healthy.
---

<section class="hero shell">
  <div class="hero-copy">
    <p class="eyebrow"><span></span>Icinga 2, without the dashboard detour</p>
    <h1>See what needs you. Ignore the rest.</h1>
    <p class="lead">IssueLight turns monitoring state into a small, native macOS signal. Healthy systems stay out of the way. Problems arrive ordered by attention, across every source you configured.</p>
    <div class="actions">
      <a class="button" href="{{ '/install.html' | relative_url }}">Build IssueLight</a>
      <a class="button secondary" href="{{ site.repository }}">View the source</a>
    </div>
    <p class="release-note"><span>Open-source preview</span> macOS 14+ · Read-only by design</p>
  </div>
  <figure class="hero-shot app-window">
    <div class="window-bar"><span></span><span></span><span></span><strong>Attention</strong></div>
    <img src="{{ '/assets/screenshots/attention-overview.png' | relative_url }}" alt="IssueLight status window ordering critical, warning and unknown Icinga issues from two monitoring sources" width="1520" height="1120">
    <figcaption>One view for actionable and already-covered issues. No green wall of reassurance.</figcaption>
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

<section class="section shell language-section">
  <div class="section-heading">
    <p class="eyebrow"><span></span>Your language, without a restart</p>
    <h2>System default or an explicit language.</h2>
    <p>Choose one of 21 built-in languages from the menu or Settings. Arabic and Urdu switch the complete interface to a right-to-left layout.</p>
  </div>
  <div class="language-grid">
    <figure class="app-window language-states">
      <img src="{{ '/assets/screenshots/menu-item-states.png' | relative_url }}" alt="IssueLight menu bar item in setup, healthy and seven-problem states" width="1080" height="184">
      <figcaption>The menu-bar signal stays compact in setup, healthy and attention states.</figcaption>
    </figure>
    <figure class="app-window">
      <img src="{{ '/assets/screenshots/menu-panel-sv.png' | relative_url }}" alt="IssueLight status menu in Swedish" width="720" height="560">
      <figcaption>Swedish menu panel</figcaption>
    </figure>
    <figure class="app-window">
      <img src="{{ '/assets/screenshots/menu-panel-ar.png' | relative_url }}" alt="IssueLight status menu in Arabic with right-to-left layout" width="720" height="560">
      <figcaption>Arabic right-to-left menu panel</figcaption>
    </figure>
  </div>
</section>

<section class="section shell security-section">
  <figure class="setup-shot app-window">
    <div class="window-bar"><span></span><span></span><span></span><strong>Source setup</strong></div>
    <img src="{{ '/assets/screenshots/source-setup.png' | relative_url }}" alt="IssueLight source setup with Icinga 2 endpoint, Basic authentication and strict macOS system trust" width="1840" height="1360">
  </figure>
  <div class="security-copy">
    <p class="eyebrow"><span></span>Secure by default</p>
    <h2>Real infrastructure deserves real trust controls.</h2>
    <p>Credentials belong in macOS Keychain. Certificate verification stays enabled unless you make a source-specific exception.</p>
    <ul class="check-list">
      <li><strong>Authentication</strong><span>Basic credentials or a selected client certificate.</span></li>
      <li><strong>Server trust</strong><span>macOS system trust, a private CA or an exact server-certificate pin.</span></li>
      <li><strong>Homelab escape hatch</strong><span>Certificate verification can be disabled per source, with an explicit warning.</span></li>
      <li><strong>No secret config files</strong><span>Source records keep references. Passwords and private keys stay in Keychain.</span></li>
    </ul>
  </div>
</section>

<section class="evidence-band">
  <div class="shell evidence-layout">
    <div>
      <p class="eyebrow"><span></span>Tested against the thing itself</p>
      <h2>A real Icinga 2 lab, not an optimistic JSON fixture.</h2>
    </div>
    <div class="matrix" role="list" aria-label="Icinga integration coverage">
      <span role="listitem">HTTP</span>
      <span role="listitem">HTTPS</span>
      <span role="listitem">Basic auth</span>
      <span role="listitem">mTLS</span>
      <span role="listitem">Private CA</span>
      <span role="listitem">Exact pinning</span>
      <span role="listitem">Rejected auth</span>
      <span role="listitem">Rejected trust</span>
    </div>
    <p class="evidence-note">The container lab drives the same public provider path used by the app. Unit tests cover deterministic domain behavior. The screenshot test renders the production SwiftUI views shown on this page.</p>
  </div>
</section>

<section class="section shell scope-section">
  <div class="section-heading">
    <p class="eyebrow"><span></span>Scope you can reason about</p>
    <h2>Icinga 2 first. Provider-neutral where it matters.</h2>
    <p>The first supported provider is Icinga 2. Provider-specific transport, authentication and decoding stop at a small core boundary, so another backend can be added without turning the UI or saved sources into Icinga-shaped state.</p>
  </div>
  <div class="scope-grid">
    <div><strong>Available now</strong><p>Multiple sources, manual and background refresh, attention ordering, search, strict TLS options, Keychain credentials and stale-state retention.</p></div>
    <div><strong>Deliberately absent</strong><p>Remote acknowledgements, downtime changes and notifications are not part of the first read-only release scope.</p></div>
    <div><strong>Release status</strong><p>The code is public and the release path is tested. A notarized public binary is not available yet, so this page does not pretend otherwise.</p></div>
  </div>
</section>

<section class="closing-band">
  <div class="shell closing-content">
    <img src="{{ '/assets/app-icon.png' | relative_url }}" alt="IssueLight lighthouse app icon" width="148" height="148">
    <div><p class="eyebrow"><span></span>Apache-2.0 open source</p><h2>Inspect it. Test it. Make the signal better.</h2><p>IssueLight is developed in public with its specifications, architecture decisions, real integration lab and release evidence in the repository.</p></div>
    <div class="actions"><a class="button" href="{{ site.repository }}">Open GitHub</a><a class="button secondary" href="{{ '/documentation.html' | relative_url }}">Read the docs</a></div>
  </div>
</section>
