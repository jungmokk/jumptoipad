import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import AVFoundation
import ScreenCaptureKit

/// A utility helper to manage and check macOS Accessibility (AX) API permissions.
/// Accessibility is strictly required for global hardware event injection (CGEvent.post).
class AccessibilityHelper {
    
    /// Request Screen Recording permission.
    static func requestScreenCapturePermission() {
        if #available(macOS 12.3, *) {
            // This reliably triggers the Screen Recording permission dialog in macOS 13+
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { _, _ in }
        } else {
            CGRequestScreenCaptureAccess()
        }
    }
    
    /// Request Audio recording/microphone permission.
    static func requestAudioCapturePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            print("[Permission] Audio capture access granted: \(granted)")
        }
    }
    
    /// Check if the application is currently authorized to use Accessibility APIs for event injection.
    static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }
    
    /// Request Accessibility permissions.
    /// If access is not granted, macOS will trigger the system security dialog.
    /// Returns true if already trusted, false otherwise.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        if isAccessibilityTrusted() {
            return true
        }
        
        // Options dictionary to prompt the user
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        
        if !trusted {
            showAccessibilityInstructionsDialog()
        }
        
        return trusted
    }
    
    /// Display user instructions to navigate Privacy & Security to approve Accessibility.
    private static func showAccessibilityInstructionsDialog() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "접근성 권한 필요 (Accessibility Permission Required)"
            alert.informativeText = """
            Jump Desktop Clone 호스트 앱이 아이패드로부터 수신한 마우스 및 키보드 입력을 시스템에 주입하여 원격 제어를 처리하기 위해 접근성(Accessibility) 권한이 필요합니다.
            
            1. [시스템 설정 (System Settings)] -> [개인정보 보호 및 보안 (Privacy & Security)] -> [접근성 (Accessibility)]으로 이동합니다.
            2. 본 애플리케이션의 토글 스위치를 '켬'으로 전환해 주십시오.
            3. 만약 목록에 이미 존재한다면, 스위치를 껐다가 다시 켜 보십시오.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "시스템 설정 열기 (Open System Settings)")
            alert.addButton(withTitle: "나중에 (Later)")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Open Privacy & Security -> Accessibility in System Settings
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                } else {
                    if let fallbackUrl = URL(string: "x-apple.systempreferences:") {
                        NSWorkspace.shared.open(fallbackUrl)
                    }
                }
            }
        }
    }
}
