import Foundation
import CoreAudio

/// Detects whether the current default audio OUTPUT is private
/// (headphones) or open-air (speakers). Determines whether Aitvaras may
/// listen while she speaks: on speakers she hears herself, so barge-in
/// must be disabled (half-duplex); on headphones full duplex is safe.
public enum AudioRoute {
    /// FourCC 'hdpn' — the built-in device's headphone-jack data source.
    private static let headphoneDataSource: UInt32 = 0x6864_706E

    public static func isHeadphones() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != 0 else { return false }

        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }

        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            // AirPods & friends. (BT speakers exist; personal audio is
            // the overwhelmingly common case — acceptable trade.)
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            // Same device for speakers and the 3.5mm jack — the data
            // source says which one is live.
            var source = UInt32(0)
            size = UInt32(MemoryLayout<UInt32>.size)
            address.mSelector = kAudioDevicePropertyDataSource
            address.mScope = kAudioObjectPropertyScopeOutput
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &source) == noErr else {
                return false
            }
            return source == headphoneDataSource
        default:
            // USB/HDMI/DisplayPort/AirPlay/virtual: could be a monitor's
            // speakers or an interface driving anything — assume open-air
            // (the safe direction: no self-interruption).
            return false
        }
    }

    public static func describe() -> String {
        isHeadphones() ? "headphones (full duplex)" : "speakers (half duplex)"
    }
}
