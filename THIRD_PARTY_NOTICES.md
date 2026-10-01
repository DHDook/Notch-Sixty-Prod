# Third-Party Notices

As of the PR42 commercial provenance review, **Notch Sixty has no linked or bundled third-party production dependency requiring a redistribution notice**.

The shipping target uses Apple platform frameworks/system libraries supplied by the macOS SDK and operating system. Public DSP/acoustic literature and public file-format/configuration specifications may inform independently authored code; those references are not bundled third-party software.

The app includes interoperability for user-selected REW, EasyEffects and CamillaDSP formats. Notch Sixty does not embed, link, or redistribute those applications or their source code. Their names are used solely to identify compatible formats/workflows and do not imply endorsement.

The app icon/identity artwork is owner-authored material cleared under the owner's independent rights; see `docs/PR39_APP_IDENTITY_STATUS.md` and `docs/PR42_PROVENANCE_CLOSURE.md`.

Before adding any future dependency, record:

- component and version;
- source URL;
- license;
- whether it is linked into or bundled with the shipping application;
- whether it is used on the realtime path;
- reason for inclusion;
- required attribution/license text.

GPL/AGPL dependencies are not permitted in production targets.
