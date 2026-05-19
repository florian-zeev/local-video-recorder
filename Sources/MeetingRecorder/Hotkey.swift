import Carbon.HIToolbox
import Foundation

final class Hotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onPress: (() -> Void)?

    private static var instances: [UInt32: Hotkey] = [:]
    private static var nextID: UInt32 = 1

    private let id: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.id = Hotkey.nextID
        Hotkey.nextID += 1
        Hotkey.instances[id] = self

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, eventRef, _) -> OSStatus in
            guard let eventRef else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            if let instance = Hotkey.instances[hkID.id] {
                DispatchQueue.main.async { instance.onPress?() }
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        let hkID = EventHotKeyID(signature: OSType(0x4D525244), id: id) // 'MRRD'
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        Hotkey.instances.removeValue(forKey: id)
    }
}
