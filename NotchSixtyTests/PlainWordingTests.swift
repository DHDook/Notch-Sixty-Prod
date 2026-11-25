import XCTest
@testable import NotchSixty

/// E12 S21: user-visible label and error providers carry no internal PR numbers or lab terms.
final class PlainWordingTests: XCTestCase {
    private func assertPlain(_ strings: [String], file: StaticString = #filePath, line: UInt = #line) {
        for s in strings {
            XCTAssertNil(
                s.range(of: #"\bPR ?\d{2,3}[A-Z]?\b"#, options: .regularExpression),
                "Internal PR number in user-visible text: \(s)", file: file, line: line)
            XCTAssertFalse(s.contains("HAL clock"), "Lab term in: \(s)", file: file, line: line)
            XCTAssertFalse(s.contains("semantic-speaker"), "Lab term in: \(s)", file: file, line: line)
        }
    }

    func testQuietZoneGateTitlesArePlain() {
        assertPlain(QuietZoneCommissioningGate.allCases.map(\.title))
        assertPlain(QuietZoneFeedForwardAcceptanceGate.allCases.map(\.title))
    }

    func testVerificationFaultDescriptionsArePlain() {
        let verification: [QuietZonePhysicalVerificationFault] = [
            .incompleteSurvey, .wrongVisitOrder, .changedHardwareRig, .changedInstrumentOrSource,
            .duplicatedEvidence, .staleOrReorderedSessions, .mismatchedFrequencyBands,
            .movedReturnMicrophone, .changedNoiseBaseline, .unstableAttenuation, .failedNumericalPreflight,
        ]
        assertPlain(verification.compactMap(\.errorDescription))
        let spectral: [QuietZonePhysicalSpectralFault] = [
            .failedCampaign, .inconsistentFrequencyReduction, .invalidEvidence, .corruptedEvidencePackage,
        ]
        assertPlain(spectral.compactMap(\.errorDescription))
    }
}
