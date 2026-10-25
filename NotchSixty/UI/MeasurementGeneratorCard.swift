import SwiftUI

/// E11 S7: Generator tab card. Edits `SignalGeneratorSettings` (noise type, level, ceiling, band presets, auto-stop).
/// Settings are published to the graph through `UnifiedGraphConfiguration.generatorParams`; the core clamps level to
/// the ceiling, ramps over 100 ms and auto-stops, whatever this card sends.
struct MeasurementGeneratorCard: View {
    @State private var settings = SignalGeneratorSettings()
    private static let octaveCentres: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    var body: some View {
        GroupBox("Signal generator") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Signal", selection: $settings.kind) {
                    Text("White").tag(SignalGeneratorSettings.Kind.white)
                    Text("Pink").tag(SignalGeneratorSettings.Kind.pink)
                    Text("Band-limited pink").tag(SignalGeneratorSettings.Kind.bandLimitedPink)
                    Text("Sine").tag(SignalGeneratorSettings.Kind.sine)
                    Text("Periodic pink").tag(SignalGeneratorSettings.Kind.periodicPink)
                }
                Slider(value: $settings.levelDB, in: -60 ... -6) {
                    Text("Level \(Int(settings.effectiveLevelDB)) dBFS RMS")
                }
                if settings.kind == .sine {
                    Stepper("Frequency \(Int(settings.sineHz)) Hz", value: $settings.sineHz, in: 20 ... 20_000, step: 10)
                }
                if settings.kind == .bandLimitedPink {
                    Menu("Octave band preset") {
                        ForEach(Self.octaveCentres, id: \.self) { centre in
                            Button("\(centre, specifier: "%g") Hz") {
                                settings.selectBand(centerHz: centre, bandFraction: 1)
                            }
                        }
                    }
                    Text("Band \(Int(settings.lowHz)) to \(Int(settings.highHz)) Hz")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Mute other audio while playing", isOn: $settings.muteOtherAudio)
                Text("Level is held at or below -6 dBFS RMS, fades over 100 ms, stops after 10 minutes and when the output changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }
}
