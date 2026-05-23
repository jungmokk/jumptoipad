import Foundation
import CoreGraphics

/// VirtualDisplayManager coordinates the creation and destruction of virtual software monitors
/// to support full Headless operations on macOS. Uses dynamic runtime resolution of CoreGraphics
/// private APIs (CGVirtualDisplay) to ensure compile-time safety and graceful OS degradation.
class VirtualDisplayManager {
    
    private var virtualDisplay: NSObject?
    private var descriptor: NSObject?
    private var settings: NSObject?
    
    private var originalMainDisplayID: CGDirectDisplayID?
    private var createdDisplayID: CGDirectDisplayID?
    
    /// Initializes a virtual display matching the client's dimensions and scale.
    /// Returns the CGDirectDisplayID if creation succeeded, nil otherwise.
    func createVirtualDisplay(width: Int, height: Int) -> CGDirectDisplayID? {
        print("[VirtualDisplay] Initializing virtual display \(width)x\(height) using dynamic CoreGraphics private API...")
        
        // Resolve undocumented classes at runtime
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type else {
            print("[VirtualDisplay] WARNING: CoreGraphics virtual display private APIs are not available on this macOS version.")
            return nil
        }
        
        let displaysBefore = getActiveDisplays()
        
        // 1. Create Descriptor
        let desc = descriptorClass.init()
        desc.setValue(DispatchQueue.global(qos: .userInteractive), forKey: "queue")
        desc.setValue("JumpDesktopVirtualDisplay", forKey: "name")
        desc.setValue(UInt32(width), forKey: "maxPixelsWide")
        desc.setValue(UInt32(height), forKey: "maxPixelsHigh")
        desc.setValue(NSValue(size: NSSize(width: width, height: height)), forKey: "sizeInMillimeters")
        desc.setValue(0x1337, forKey: "productID")
        desc.setValue(0x1337, forKey: "vendorID")
        desc.setValue(1, forKey: "serialNum")
        self.descriptor = desc
        
        // 2. Create Display
        guard let unmanagedDisplay = displayClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        guard let display = unmanagedDisplay.perform(NSSelectorFromString("initWithDescriptor:"), with: desc)?.takeUnretainedValue() as? NSObject else { return nil }
        self.virtualDisplay = display
        
        // 3. Configure Settings & Mode
        let sets = settingsClass.init()
        sets.setValue(1, forKey: "hiDPI") // Retina scaling
        
        let mode = modeClass.init()
        mode.setValue(UInt32(width), forKey: "width")
        mode.setValue(UInt32(height), forKey: "height")
        mode.setValue(60.0, forKey: "refreshRate")
        
        sets.setValue([mode], forKey: "modes")
        self.settings = sets
        
        // 4. Apply Settings
        display.perform(NSSelectorFromString("applySettings:"), with: sets)
        
        // 5. Detect new display ID
        var newDisplayID: CGDirectDisplayID?
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.1)
            let displaysAfter = getActiveDisplays()
            if let added = displaysAfter.first(where: { !displaysBefore.contains($0) }) {
                newDisplayID = added
                break
            }
        }
        
        guard let displayID = newDisplayID else {
            print("[VirtualDisplay] Failed to detect the new virtual display ID.")
            return nil
        }
        
        self.createdDisplayID = displayID
        self.originalMainDisplayID = CGMainDisplayID()
        
        print("[VirtualDisplay] Successfully created Virtual Display. ID: \(displayID)")
        
        // 6. Make Virtual Display the Main Display
        makeMainDisplay(displayID: displayID, originalMainID: originalMainDisplayID!)
        
        return displayID
    }
    
    /// Tears down the virtual display and releases the associated framebuffers.
    func destroyVirtualDisplay() {
        print("[VirtualDisplay] Destroying virtual display and releasing resources.")
        
        // Revert main display back
        if let origMain = originalMainDisplayID, let created = createdDisplayID {
            print("[VirtualDisplay] Restoring original main display.")
            var configRef: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&configRef)
            CGConfigureDisplayOrigin(configRef, origMain, 0, 0)
            CGConfigureDisplayOrigin(configRef, created, Int32(CGDisplayPixelsWide(origMain)), 0)
            CGCompleteDisplayConfiguration(configRef, .forSession)
        }
        
        virtualDisplay = nil
        descriptor = nil
        settings = nil
        createdDisplayID = nil
        originalMainDisplayID = nil
    }
    
    // ─── Private Helpers ───
    
    private func getActiveDisplays() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        return displays
    }
    
    private func makeMainDisplay(displayID: CGDirectDisplayID, originalMainID: CGDirectDisplayID) {
        var configRef: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&configRef)
        
        // Move the original main display out of the way
        let currentWidth = CGDisplayPixelsWide(displayID)
        CGConfigureDisplayOrigin(configRef, originalMainID, Int32(currentWidth), 0)
        
        // Set the new display to (0,0) making it the primary display with Menu Bar and Dock
        CGConfigureDisplayOrigin(configRef, displayID, 0, 0)
        
        CGCompleteDisplayConfiguration(configRef, .forSession)
        
        let actualWidth = CGDisplayPixelsWide(displayID)
        let actualHeight = CGDisplayPixelsHigh(displayID)
        print("[VirtualDisplay] Display \(displayID) set as Main Display. Active resolution: \(actualWidth)x\(actualHeight)")
    }
}
