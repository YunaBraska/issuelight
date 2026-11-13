---
layout: default
title: Documentation
description: Product, security, development and integration documentation for IssueLight.
---

<section class="page-hero shell">
  <p class="eyebrow"><span></span>Documentation</p>
  <h1>Follow the evidence.</h1>
  <p>Start with the product status when you need the honest boundary. Use the specifications for accepted behavior and the development guide when you want to build or test the app.</p>
</section>

<section class="document-list shell">
  <a href="{{ site.repository }}/blob/main/docs/PROJECT_STATUS.md"><span>Status</span><strong>What works and what still blocks a public release</strong><p>Verified behavior, coverage and remaining release risks.</p></a>
  <a href="{{ site.repository }}/blob/main/docs/spec/source-connection.md"><span>Specification</span><strong>Source connection and TLS behavior</strong><p>Endpoints, authentication, trust choices and explicit failure behavior.</p></a>
  <a href="{{ site.repository }}/blob/main/docs/spec/attention-snapshot.md"><span>Specification</span><strong>Attention and refresh model</strong><p>Issue ordering, covered states, stale data and refresh ownership.</p></a>
  <a href="{{ site.repository }}/blob/main/docs/spec/multiple-sources.md"><span>Specification</span><strong>Multiple monitoring sources</strong><p>Independent configuration, refresh and aggregation behavior.</p></a>
  <a href="{{ site.repository }}/blob/main/integration/icinga2/README.md"><span>Integration</span><strong>Real Icinga 2 compatibility lab</strong><p>HTTP, HTTPS, authentication, private CA, pinning and mTLS scenarios.</p></a>
  <a href="{{ site.repository }}/blob/main/docs/DEVELOPMENT.md"><span>Development</span><strong>Build, test and package IssueLight</strong><p>Local toolchain, coverage ratchet and release-candidate workflow.</p></a>
  <a href="{{ site.repository }}/tree/main/docs/adr"><span>Architecture</span><strong>Recorded decisions</strong><p>Provider boundaries, trust storage, release artifacts and update scope.</p></a>
  <a href="{{ site.repository }}/blob/main/SECURITY.md"><span>Security</span><strong>Report a vulnerability privately</strong><p>Supported reporting channel and disclosure expectations.</p></a>
</section>
