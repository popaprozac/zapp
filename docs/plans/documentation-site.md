# Zapp documentation site

Accepted direction: publish Zapp's developer documentation at
`https://zapp.z-language.com` as the official desktop framework built with Z.
The site has not been deployed yet.

Z remains a general-purpose systems language. Zapp has its own repository,
configuration, APIs, documentation, and release lifecycle; official-project
positioning does not make desktop-framework concepts part of the language.

## Audience and content

Lead with developers building applications, not implementation history:

- Getting started and a runnable Z Notes walkthrough.
- Application, windows, services, workers, and lifecycle guides.
- TypeScript runtime and native Z API reference.
- Configuration, permissions, build, development, and packaging.
- Explicit platform support and nearby limitations for each affected feature.

Use the existing `docs/` developer guides as the source material. Keep plans,
research, historical code, and compiler investigations separate from supported
usage. Link language and ownership explanations to the Z documentation instead
of maintaining competing copies.

## Presentation and delivery

Use the Z documentation's visual language while keeping Zapp navigation and
product identity distinct. The existing Z Astro/Starlight site is a useful
implementation reference. Preserve Z-aware code highlighting alongside
TypeScript examples.

Before publication, settle one source of truth for guides, verify examples and
links, and clearly label the current macOS-focused implementation. Domain/DNS
and hosting configuration are a separate deployment step; recording the domain
here does not mean it is already serving the site.
