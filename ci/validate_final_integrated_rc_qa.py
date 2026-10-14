#!/usr/bin/env python3
"""Final-stack integrated remote RC audit. Never confers physical or signing authority."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT=Path(__file__).resolve().parents[1]
PARENTS={
    "acoustic-reference":"e687bdd0cda7e7e19c6b4a7b3f33e25b45156534",
    "acoustic-intelligence":"7d10a2340be732b3110fd418e97d865ecce3967f",
    "headphones":"256ec109aed8f73b59b240f89d9ff4a11076f0ed",
    "product-validation":"842f799b1e744575a0ffebecfd593bf0210ddfe2",
    "optional-research":"141e2776290d5ea02ccbad93a9ab37e6f1a0bf0f",
}
SOURCES=(
    "NotchSixty/UI/ProductionRootView.swift",
    "NotchSixty/UI/ProductionHeadphoneWorkspace.swift",
    "NotchSixty/UI/ProductionOptionalAudioResearchWorkspace.swift",
    "NotchSixty/Audio/OptionalAcousticResearch.swift",
    "NotchSixty/Audio/Routing/HeadphoneModelResearchLibrary.swift",
    "NotchSixty/Audio/Routing/BlindABXValidation.swift",
    "NotchSixty/Audio/UnifiedAcousticIntelligenceCoordinator.swift",
    "NotchSixty.xcodeproj/project.pbxproj",
    "NotchSixty/Info.plist",
    "NotchSixty/NotchSixty.entitlements",
    "NotchSixty/ThirdPartyNotices.txt",
    "THIRD_PARTY_NOTICES.md",
    "docs/PROVENANCE.md",
    "release/production-dependencies.json",
    "docs/FINAL_INTEGRATED_RC_QA.md",
)
FALSE=(
    "physicalAcceptanceComplete","productionAppleSigningComplete",
    "appStoreConnectUploadComplete","testFlightAcceptanceComplete",
    "appReviewApproved","developerIDNotarizationComplete",
    "publicReleaseAuthorized","liveFeedForwardANCAuthorized",
    "mayMergeIntoMain","physicalEvidenceSuppliedByCI",
    "finalAppIconOwnerApproved","appStorePrivacyPolicyURLConfigured",
    "appStorePrivacyResponsesComplete",
)
def require(ok, msg):
    if not ok: raise ValueError("Final RC/QA: "+msg)
def text(path):
    target=ROOT/path
    require(target.is_file(), "missing source "+path)
    return target.read_text(encoding="utf-8")
def sha(path):
    h=hashlib.sha256()
    with Path(path).open("rb") as f:
        for part in iter(lambda:f.read(1024*1024),b""):h.update(part)
    return h.hexdigest()
def git(*args):
    return subprocess.check_output(["git",*args],cwd=ROOT,text=True).strip()
def audit_source():
    for f in SOURCES: require((ROOT/f).is_file(),"missing "+f)
    root=text("NotchSixty/UI/ProductionRootView.swift")
    for s in ("case acousticResearch","case blindListening","case roomAdvisor",
              "case headphones","ProductionOptionalAudioResearchWorkspace",
              "ProductionBlindListeningWorkspace"):
        require(s in root,"missing shipped destination "+s)
    pbx=text("NotchSixty.xcodeproj/project.pbxproj")
    for f in ("OptionalAcousticResearch.swift","HeadphoneModelResearchLibrary.swift",
              "ProductionOptionalAudioResearchWorkspace.swift",
              "OptionalAudioResearchTests.swift","BlindABXValidationTests.swift"):
        require(pbx.count(f)>=4,"target membership missing "+f)
    for f in ("NotchSixty/Audio/OptionalAcousticResearch.swift",
              "NotchSixty/Audio/Routing/HeadphoneModelResearchLibrary.swift"):
        s=text(f)
        require(("canDeploy: Bool { false }" in s or
                 "canApply: Bool { false }" in s),"research must not auto-deploy")
        for forbidden in ("AudioObjectSetPropertyData(","N60RenderKernelConfigure(",
                          "N60RealtimeAudioBridgeConfigure("):
            require(forbidden not in s,"research unexpectedly writes realtime state")
    ent=plistlib.loads((ROOT/"NotchSixty/NotchSixty.entitlements").read_bytes())
    require(ent.get("com.apple.security.app-sandbox") is True,
            "shipping app sandbox disabled")
    for unsafe in ("com.apple.security.network.server",
                   "com.apple.security.cs.allow-unsigned-executable-memory"):
        require(ent.get(unsafe) is not True,"unsafe entitlement "+unsafe)
    info=plistlib.loads((ROOT/"NotchSixty/Info.plist").read_bytes())
    for key in ("NSAudioCaptureUsageDescription","NSMicrophoneUsageDescription"):
        require(bool(str(info.get(key,"")).strip()),"privacy purpose missing "+key)
    deps=json.loads(text("release/production-dependencies.json"))
    require(deps["policy"]["unclassifiedProductionDependencyAllowed"] is False,
            "unclassified dependency permitted")
    for file in ("NotchSixty/ThirdPartyNotices.txt","THIRD_PARTY_NOTICES.md"):
        require("libmysofa" in text(file),"libmysofa notice absent")
    baseline=json.loads(text("release/pr114-release-baseline.json"))
    for f in ("physicalAcceptanceComplete","mayMergeIntoMain","publicReleaseAuthorized"):
        require(baseline["releaseAuthority"].get(f) is False,"release authority promoted")
    wf=text(".github/workflows/final-integrated-rc-qa.yml")
    for token in ("xcodebuild archive","hdiutil create","codesign --verify",
                  "build_pr114_release_candidate_manifest.py","full_xctest",
                  "validate_final_integrated_rc_qa.py"):
        require(token in wf,"final RC workflow missing "+token)
    print("Final integrated source/rights/safety/research contract: PASS")
def audit_package(args):
    head=git("rev-parse","HEAD")
    require(re.fullmatch(r"[a-f0-9]{40}",head) is not None,"full SHA required")
    require(args.run_id.isdigit(),"numeric Actions run ID required")
    for label,parent in PARENTS.items():
        r=subprocess.run(["git","merge-base","--is-ancestor",parent,head],
                         cwd=ROOT,check=False)
        require(r.returncode==0,"missing tested parent "+label)
    for x in (args.manifest,args.dmg,args.sbom):require(x.is_file(),"missing packaged file")
    m=json.loads(args.manifest.read_text())
    require(m.get("sourceCommitSHA")==head,"package commit mismatch")
    require(str(m.get("githubRunID"))==args.run_id,"package run mismatch")
    require(m.get("remoteCommercialRCSoftwareComplete") is True,
            "PR114 package preflight incomplete")
    require(m.get("remotePassedCount")==m.get("remoteRequirementCount"),
            "some PR114 gates incomplete")
    p=m.get("packaging",{})
    require(p.get("remoteRCPackageSignature")=="ad-hoc","test package not ad-hoc")
    require(p.get("remoteRCPackageNotarized") is False and
            p.get("remoteRCPackagePublicDistributionReady") is False,
            "public distribution incorrectly authorized")
    require(m["artifacts"]["remoteRCDMGSHA256"]==sha(args.dmg),
            "DMG checksum mismatch")
    require(m["artifacts"]["productionSBOMSHA256"]==sha(args.sbom),
            "SBOM checksum mismatch")
    sb=json.loads(args.sbom.read_text())
    require(sb.get("bomFormat")=="CycloneDX" and sb.get("specVersion")=="1.5",
            "CycloneDX SBOM invalid")
    props={x["name"]:x["value"]
           for x in sb["metadata"]["component"]["properties"]}
    require(props.get("notchsixty:sourceCommit")==head,"SBOM commit mismatch")
    for f in FALSE:
        require(m.get("releaseAuthority",{}).get(f) is False,
                "release right promoted "+f)
    result={
        "schemaVersion":1,"campaign":"FINAL_INTEGRATED_RC_QA",
        "evidenceAuthority":"remoteSoftware","sourceCommitSHA":head,
        "githubRunID":args.run_id,"sourceTreeSHA":git("rev-parse","HEAD^{tree}"),
        "testedAncestorHeads":PARENTS,
        "softwareRCPreflightComplete":True,
        "product":m["product"],
        "nominalNumericalSampleRatesHz":[44100,48000,88200,96000,176400,
                                         192000,352800,384000],
        "package":{"filename":args.dmg.name,"DMGSHA256":sha(args.dmg),
                   "manifestSHA256":sha(args.manifest),
                   "CycloneDXSHA256":sha(args.sbom),
                   "signature":"ad-hoc","notarized":False,
                   "publicDistributionReady":False},
        "sourceSHA256":{f:sha(ROOT/f) for f in SOURCES},
        "physicalH01ThroughH08Accepted":False,
        "native384kHzDACVerified":False,
        "speakerSubwooferAcousticAcceptance":False,
        "headphoneSPLAndIndividualHRTFVerified":False,
        "independentPhysicalSubOutputClockVerified":False,
        "externalLegalAndDataRightsReviewed":False,
        "ownerMergeOrReleaseApproval":False,
        "ownerChecklist":[
            "Perform H01-H08 hardware tests on the exact Mac/Playback System",
            "Check device reconnect, sleep/wake, endurance, CPU and underflow",
            "Measure real calibrated speaker, subwoofer, driver FIR responses",
            "Verify actual native DAC rates including 384kHz as supported",
            "Verify multichannel/sub output clock and routing when enabled",
            "Check headphone SPL, per-ear PEQ and real HRTF audition",
            "Review licenses, third-party measurements and privacy disclosures",
            "Supply Apple signing credentials; perform TestFlight/notarization",
            "Approve each stacked PR merge and any release explicitly"
        ],
        **{flag:False for flag in FALSE},
    }
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2,sort_keys=True)+"\n")
    print("Final integrated RC exact-head ad-hoc DMG, SBOM and handoff: PASS")
def main():
    p=argparse.ArgumentParser()
    p.add_argument("--source-only",action="store_true")
    p.add_argument("--manifest",type=Path)
    p.add_argument("--dmg",type=Path)
    p.add_argument("--sbom",type=Path)
    p.add_argument("--output",type=Path)
    p.add_argument("--run-id",default="")
    a=p.parse_args()
    audit_source()
    if a.source_only:
        require(all(x is None for x in (a.manifest,a.dmg,a.sbom,a.output)),
                "cannot claim artifact certificate from source-only check")
        return
    require(all(x is not None for x in (a.manifest,a.dmg,a.sbom,a.output)),
            "artifact audit requires real DMG/manifest/SBOM/output")
    audit_package(a)
if __name__=="__main__":
    try:main()
    except (ValueError,KeyError,TypeError,OSError) as e:
        print(str(e));raise SystemExit(1)
