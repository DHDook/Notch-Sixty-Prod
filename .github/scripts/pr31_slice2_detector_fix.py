from pathlib import Path

p = Path('NotchSixty/Audio/Realtime/N60Dynamics.c')
text = p.read_text()
old = '''    double backgroundMean = backgroundCount > 0 ? background / (double)backgroundCount : 0.0;
    double n = (double)runtime->mainsDetectorSampleCount;
    double normalizedTonePower = 4.0 * bestPower / fmax(n * n, 1.0);
    double levelDBFS = 10.0 * log10(fmax(normalizedTonePower, 1.0e-20));
    double prominence = bestPower > 1.0e-20 ? 1.0 - backgroundMean / bestPower : 0.0;
    prominence = fmin(fmax(prominence, 0.0), 1.0);
    if (levelDBFS < N60_MAINS_DETECTOR_MIN_LEVEL_DBFS) prominence = 0.0;
'''
new = '''    double backgroundMean = backgroundCount > 0 ? background / (double)backgroundCount : 0.0;
    double n = (double)runtime->mainsDetectorSampleCount;
    // A relative spectral peak alone is not enough evidence of mains hum: an
    // out-of-band coherent tone can create a locally prominent leakage bin.
    // Require the candidate sinusoid to explain meaningful time-domain energy
    // in the detector window as well as standing above neighboring bins.
    double candidateMeanSquare = 2.0 * bestPower / fmax(n * n, 1.0);
    double totalMeanSquare = runtime->mainsDetectorWindowEnergy / fmax(n, 1.0);
    double levelDBFS = 10.0 * log10(fmax(candidateMeanSquare, 1.0e-20));
    double prominence = bestPower > 1.0e-20 ? 1.0 - backgroundMean / bestPower : 0.0;
    prominence = fmin(fmax(prominence, 0.0), 1.0);
    double toneEnergyFraction = candidateMeanSquare / fmax(totalMeanSquare, 1.0e-20);
    toneEnergyFraction = fmin(fmax(toneEnergyFraction, 0.0), 1.0);
    double confidence = prominence * toneEnergyFraction;
    if (levelDBFS < N60_MAINS_DETECTOR_MIN_LEVEL_DBFS) confidence = 0.0;
'''
if old not in text:
    raise SystemExit('detector confidence anchor not found')
text = text.replace(old, new, 1)
text = text.replace('    runtime->mainsDetectionConfidence = (float)prominence;\n', '    runtime->mainsDetectionConfidence = (float)confidence;\n', 1)
p.write_text(text)
