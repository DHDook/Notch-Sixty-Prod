# Document schemas

JSON Schema (2020-12) for the three persisted documents: room-correction project (v2), profile snapshot (v1) and backup bundle (v1). Fixtures sit in `schemas/fixtures`; `DocumentSchemaTests` checks them (E21 S13, G24).

## Why the sub-configurations stay open

The schemas pin keys and types down to the preset, system-state, project and bundle levels. Sub-configurations (EQ, dynamics, rack, routing, targetShaping, ancBassFingerprint, output bindings), measurement-lab sessions and binaural assets are deliberately open objects:

- Each is still changing under epics that have not shipped (E4, E24, E28, E33). A closed schema now would be rewritten with each of them and would add a version bump per change with no reader to benefit.
- The Swift Codable types are the source of truth and already reject malformed documents at decode. The schemas are test-checked only; there is no runtime validation and no non-Apple shell consumer yet.
- The first non-Apple shell that reads these documents deepens the sections it needs, together with a version bump and a fixture.

Project dates are seconds since 2001 on disk and milliseconds since 1970 in a bundle; both are typed "number". Consumers must convert by document type.
