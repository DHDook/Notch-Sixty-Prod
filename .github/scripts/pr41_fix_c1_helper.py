from pathlib import Path

path = Path('.github/scripts/pr41_slice_c1.py')
text = path.read_text()

old = """device = replace_once(\n    device,\n    '''    let nominalSampleRate: Double\\n    let availableSampleRateRanges: [AudioSampleRateRange]\\n\\n    var id: String { uid }\\n''',\n    '''    let nominalSampleRate: Double\\n    let availableSampleRateRanges: [AudioSampleRateRange]\\n    let outputChannelCount: UInt32\\n\\n    init(\\n        deviceID: AudioDeviceID,\\n        uid: String,\\n        name: String,\\n        nominalSampleRate: Double,\\n        availableSampleRateRanges: [AudioSampleRateRange],\\n        outputChannelCount: UInt32 = 2\\n    ) {\\n        self.deviceID = deviceID\\n        self.uid = uid\\n        self.name = name\\n        self.nominalSampleRate = nominalSampleRate\\n        self.availableSampleRateRanges = availableSampleRateRanges\\n        self.outputChannelCount = outputChannelCount\\n    }\\n\\n    var id: String { uid }\\n''',\n    \"AudioOutputDevice channel metadata\",\n)\n"""
new = """device = replace_once(\n    device,\n    '''struct AudioOutputDevice: Identifiable, Equatable, Sendable {\\n    typealias ID = String\\n\\n    let deviceID: AudioDeviceID\\n    let uid: String\\n    let name: String\\n    let nominalSampleRate: Double\\n    let availableSampleRateRanges: [AudioSampleRateRange]\\n\\n    var id: String { uid }\\n''',\n    '''struct AudioOutputDevice: Identifiable, Equatable, Sendable {\\n    typealias ID = String\\n\\n    let deviceID: AudioDeviceID\\n    let uid: String\\n    let name: String\\n    let nominalSampleRate: Double\\n    let availableSampleRateRanges: [AudioSampleRateRange]\\n    let outputChannelCount: UInt32\\n\\n    init(\\n        deviceID: AudioDeviceID,\\n        uid: String,\\n        name: String,\\n        nominalSampleRate: Double,\\n        availableSampleRateRanges: [AudioSampleRateRange],\\n        outputChannelCount: UInt32 = 2\\n    ) {\\n        self.deviceID = deviceID\\n        self.uid = uid\\n        self.name = name\\n        self.nominalSampleRate = nominalSampleRate\\n        self.availableSampleRateRanges = availableSampleRateRanges\\n        self.outputChannelCount = outputChannelCount\\n    }\\n\\n    var id: String { uid }\\n''',\n    \"AudioOutputDevice channel metadata\",\n)\n"""
if text.count(old) != 1:
    raise SystemExit(f'expected one AudioOutputDevice helper block, found {text.count(old)}')
text = text.replace(old, new, 1)

old_reduce = 'return UnsafeMutableAudioBufferListPointer(list).reduce(0) { partial, buffer in\\n'
new_reduce = 'return UnsafeMutableAudioBufferListPointer(list).reduce(UInt32(0)) { partial, buffer in\\n'
if text.count(old_reduce) != 1:
    raise SystemExit(f'expected one channel-count reduce, found {text.count(old_reduce)}')
text = text.replace(old_reduce, new_reduce, 1)

path.write_text(text)
print('PR41 C1 helper targeting fixed')
