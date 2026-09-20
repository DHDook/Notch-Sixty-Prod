# Clean-Room Policy

This repository must remain independently implementable and commercially licensable.

## Prohibited source imports
Do not copy or mechanically adapt code, tests, scripts, project files, resources, assets, presets, or configuration from the historical GPL Notch Sixty / Equaliser codebase.

Do not recreate historical source structure merely by renaming identifiers.

## Allowed implementation references
Use:
- Apple public documentation and SDK headers
- public DSP specifications and papers
- independently written product requirements
- independently derived equations
- public standards
- clean behavioral test cases

## POC relationship
`CoreAudioTapPOC-N60` is separate owner-authored validation work and may inform behavior and architecture. Production code should not blindly promote POC source. Any deliberate source reuse must be noted in `PROVENANCE.md`, reviewed for ownership, and improved for production quality.

## Historical functionality
A feature may be reimplemented because functionality and standard algorithms are needed. The implementation must be independently structured from specifications rather than copied expression.

## Review rule
If a contributor is unsure whether a file or snippet is safe to reuse, classify it as **rewrite from specification** until provenance is resolved.
