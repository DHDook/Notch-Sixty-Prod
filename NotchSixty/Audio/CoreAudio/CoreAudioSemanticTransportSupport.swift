import AudioToolbox
import CoreAudio
import Darwin
import Foundation

enum CoreAudioSemanticTransportSupport {
    static func currentProcessObjectID(operationPrefix: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &dataSize,
                &processObject
            )
        }
        try check(status, operation: "\(operationPrefix): translate PID to process object")
        guard processObject != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioTransportError.processObjectUnavailable
        }
        return processObject
    }

    static func resolveInputChannelDescriptions(
        deviceID: AudioDeviceID,
        channelCount: UInt32
    ) throws -> [AudioChannelDescription] {
        if let preferred = try readPreferredChannelLayout(deviceID: deviceID),
           let descriptions = try expandChannelLayout(
                preferred,
                expectedChannelCount: channelCount
           ) {
            return descriptions
        }
        // Stereo is the only safe metadata-free fallback.
        if channelCount == 2 {
            var left = AudioChannelDescription()
            left.mChannelLabel = kAudioChannelLabel_Left
            var right = AudioChannelDescription()
            right.mChannelLabel = kAudioChannelLabel_Right
            return [left, right]
        }
        throw LiveNChannelTransportError.inputChannelLayoutUnavailable(
            channelCount: channelCount
        )
    }

    static func readPreferredChannelLayout(
        deviceID: AudioDeviceID
    ) throws -> Data? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelLayout,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard sizeStatus == noErr,
              size >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return nil }
        var data = Data(count: Int(size))
        let status = data.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        return status == noErr ? data : nil
    }

    static func expandChannelLayout(
        _ layoutData: Data,
        expectedChannelCount: UInt32
    ) throws -> [AudioChannelDescription]? {
        try layoutData.withUnsafeBytes { raw -> [AudioChannelDescription]? in
            guard let base = raw.baseAddress,
                  raw.count >= MemoryLayout<AudioChannelLayout>.size else { return nil }
            let layout = base.assumingMemoryBound(to: AudioChannelLayout.self)
            if layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
                return copyExplicitDescriptions(layout, count: expectedChannelCount)
            }

            let property: AudioFormatPropertyID
            var specifier = UInt32(0)
            if layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap {
                property = kAudioFormatProperty_ChannelLayoutForBitmap
                specifier = layout.pointee.mChannelBitmap.rawValue
            } else {
                property = kAudioFormatProperty_ChannelLayoutForTag
                specifier = layout.pointee.mChannelLayoutTag
            }

            var expandedSize: UInt32 = 0
            let infoStatus = withUnsafePointer(to: &specifier) { pointer in
                AudioFormatGetPropertyInfo(
                    property,
                    UInt32(MemoryLayout<UInt32>.size),
                    pointer,
                    &expandedSize
                )
            }
            guard infoStatus == noErr,
                  expandedSize >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return nil }
            let expanded = UnsafeMutableRawPointer.allocate(
                byteCount: Int(expandedSize),
                alignment: MemoryLayout<AudioChannelLayout>.alignment
            )
            defer { expanded.deallocate() }
            let propertyStatus = withUnsafePointer(to: &specifier) { pointer in
                AudioFormatGetProperty(
                    property,
                    UInt32(MemoryLayout<UInt32>.size),
                    pointer,
                    &expandedSize,
                    expanded
                )
            }
            guard propertyStatus == noErr else { return nil }
            return copyExplicitDescriptions(
                expanded.assumingMemoryBound(to: AudioChannelLayout.self),
                count: expectedChannelCount
            )
        }
    }

    static func copyExplicitDescriptions(
        _ layout: UnsafePointer<AudioChannelLayout>,
        count: UInt32
    ) -> [AudioChannelDescription]? {
        var descriptions = [AudioChannelDescription](
            repeating: AudioChannelDescription(),
            count: Int(count)
        )
        let copied = descriptions.withUnsafeMutableBufferPointer { buffer in
            N60CoreAudioCopyExplicitChannelDescriptions(
                layout,
                count,
                buffer.baseAddress!
            )
        }
        return copied ? descriptions : nil
    }

    static func waitForDeviceAlive(
        _ deviceID: AudioDeviceID,
        operationPrefix: String
    ) throws {
        for _ in 0..<300 {
            let alive = try readUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceIsAlive,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "\(operationPrefix): read aggregate readiness"
            )
            if alive != 0 { return }
            usleep(10_000)
        }
        throw LiveNChannelTransportError.aggregateDeviceNotReady
    }

    static func readStreamFormat(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &format),
            operation: operation
        )
        return format
    }

    static func readUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value),
            operation: operation
        )
        return value
    }

    static func writeUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        value: UInt32,
        operation: String
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableValue = value
        try check(
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &mutableValue
            ),
            operation: operation
        )
    }

    static func writeFloat64Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        value: Float64,
        operation: String
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableValue = value
        try check(
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float64>.size),
                &mutableValue
            ),
            operation: operation
        )
    }

    static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioTransportError.operationFailed(
                operation: operation,
                status: status
            )
        }
    }
}
