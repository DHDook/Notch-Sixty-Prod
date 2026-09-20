# Provenance Register

This file is the commercial repository's living provenance register.

## Classification

Each nontrivial imported/reused implementation should be classified as one of:

- **Original commercial implementation** — written in this repository from product requirements/public specifications.
- **POC-derived, owner-authored** — deliberately reused or adapted from `CoreAudioTapPOC-N60` after review.
- **Third-party permissive** — external component with compatible license and notice.
- **Specification-derived** — implemented from a public mathematical/technical specification.
- **Asset with verified rights** — images/audio/fonts/resources whose commercial rights are documented.

Historical GPL Notch Sixty / Equaliser source is not a permitted production source category.

## Initial register

| Area | Classification | Source of truth | Notes |
|---|---|---|---|
| Commercial repo bootstrap/docs | Original commercial implementation | Product requirements + clean-room architecture decisions | No GPL source imported |
| Core Audio process-tap architecture | Specification-derived / owner-validated behavior | Apple public Core Audio APIs + separate POC evidence | Production code not yet added |
| Realtime architecture | Original commercial implementation | Product requirements + realtime design rules | Production code not yet added |
| DSP implementations | Pending | Public specs / independent derivations | Add per-module entries as implemented |
| Third-party dependencies | None approved | — | Update before adding any dependency |
| Assets | None added | — | Verify rights before inclusion |

## Required entry for reused POC source

If code is intentionally reused from the POC, add:
- production path
- POC source path/commit
- ownership basis
- changes made for production
- reviewer/date

Do not treat architectural similarity by itself as source reuse.
