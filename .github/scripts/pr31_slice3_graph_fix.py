from pathlib import Path

# Normalize the scratch-buffer replacement after the main generator. The first
# pass intentionally replaces all remaining local-array references; this removes
# the duplicated qualifier on references it had already converted explicitly.
c = Path('NotchSixty/Audio/Realtime/N60SpectralDenoiser.c')
text = c.read_text().replace('runtime->runtime->linkedPower', 'runtime->linkedPower')
c.write_text(text)

# Swift max() is binary, not variadic.
tests = Path('NotchSixtyTests/NotchSixtyTests.swift')
text = tests.read_text().replace(
    'maxMagnitude = max(maxMagnitude, abs(left), abs(right))',
    'maxMagnitude = max(maxMagnitude, max(abs(left), abs(right)))'
)
tests.write_text(text)

# A quality change only changes audible graph structure when the denoiser is
# active (or being enabled). Do not fade the whole graph for an inaudible edit
# while the denoiser remains disabled.
sw = Path('NotchSixty/Audio/AudioIOEngine.swift')
text = sw.read_text().replace(
    '''            let denoiserStructureChanged = dynamicsConfiguration.spectralDenoiser.enabled != configuration.spectralDenoiser.enabled
                || dynamicsConfiguration.spectralDenoiser.quality != configuration.spectralDenoiser.quality
''',
    '''            let denoiserStructureChanged = dynamicsConfiguration.spectralDenoiser.enabled != configuration.spectralDenoiser.enabled
                || (configuration.spectralDenoiser.enabled
                    && dynamicsConfiguration.spectralDenoiser.quality != configuration.spectralDenoiser.quality)
'''
)
sw.write_text(text)
