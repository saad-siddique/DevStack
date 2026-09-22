// HotKey.swift — one global shortcut, ⌃⌥D, to open the panel from anywhere (Carbon RegisterEventHotKey; no
// accessibility permission needed). The handler is a C callback, so the action lives in a static slot.
import AppKit
import Carbon.HIToolbox

final class HotKey {
	private static var action: (() -> Void)?
	private var ref: EventHotKeyRef?
	private var handler: EventHandlerRef?

	init(action: @escaping () -> Void) {
		HotKey.action = action
		var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
		InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
			DispatchQueue.main.async { HotKey.action?() }
			return noErr
		}, 1, &spec, nil, &handler)
		let id = EventHotKeyID(signature: OSType(0x4456_5354), id: 1)   // "DVST"
		RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
	}

	deinit {
		if let ref { UnregisterEventHotKey(ref) }
		if let handler { RemoveEventHandler(handler) }
	}
}
