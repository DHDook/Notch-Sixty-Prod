# Third-Party Notices

Notch Sixty is proprietary software, but the production application now includes
one approved vendored third-party component.

## libmysofa v1.3.4

- **Upstream:** `hoene/libmysofa`, tag `v1.3.4`
- **License:** BSD 3-Clause
- **Production use:** a minimal reader/HDF subset is vendored under
  `NotchSixty/Audio/SOFA/Vendor/libmysofa` and compiled into the application
  to decode user-selected SOFA/HRTF files.
- **Realtime use:** native SOFA parsing is a control/offline import operation;
  the vendored parser is not called from the realtime audio render callback.
- **Redistribution:** the exact upstream license remains at
  `NotchSixty/Audio/SOFA/Vendor/libmysofa/LICENSE`. PR102 also ships
  `NotchSixty/ThirdPartyNotices.txt` as an application resource so the
  required BSD notice accompanies binary redistribution.

The app does **not** bundle upstream sample SOFA datasets.

## Interoperability references

The app includes interoperability for user-selected REW, EasyEffects and
CamillaDSP formats. Notch Sixty does not embed, link, or redistribute those
applications or their source code. Their names identify compatible
formats/workflows only and do not imply endorsement.

The shipping target also uses Apple platform frameworks/system libraries
supplied by the macOS SDK and operating system. Public DSP/acoustic literature
and public file-format/configuration specifications may inform independently
authored code; those references are not bundled third-party software.

The app icon/identity artwork is owner-controlled material documented in
`docs/PR39_APP_IDENTITY_STATUS.md` and
`docs/PR42_PROVENANCE_CLOSURE.md`.

Before adding any future dependency, record:

- component and version;
- source URL;
- license;
- whether it is linked into or bundled with the shipping application;
- whether it is used on the realtime path;
- reason for inclusion; and
- required attribution/license text.

GPL/AGPL dependencies are not permitted in production targets.
