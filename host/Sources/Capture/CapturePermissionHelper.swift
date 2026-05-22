import Foundation
import CoreGraphics
import AppKit

/// A utility helper to manage and check macOS screen recording permissions.
class CapturePermissionHelper {
    
    /// Check if the application currently has Screen Recording (Screen Capture) permission.
    /// On macOS 10.15+ (Catalina), Screen Recording access is strictly enforced.
    static func hasScreenCapturePermission() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true // Prior to Catalina, no explicit screen recording permission was required
    }
    
    /// Request Screen Recording permission.
    /// If access is not granted, macOS will present a system authorization prompt.
    /// Returns true if access was already granted, false otherwise.
    @discardableResult
    static func requestScreenCapturePermission() -> Bool {
        if #available(macOS 10.15, *) {
            if hasScreenCapturePermission() {
                return true
            }
            
            // Trigger the native macOS screen capture prompt
            CGRequestScreenCaptureAccess()
            
            // Guide the user with instructions since the system prompt might be subtle or require app relaunch
            showPermissionInstructionsDialog()
            return false
        }
        return true
    }
    
    /// Display a user-friendly custom dialog explaining how to grant Screen Recording permissions.
    private static func showPermissionInstructionsDialog() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "화면 기록 권한 필요 (Screen Recording Permission Required)"
            alert.informativeText = """
            Jump Desktop Clone 호스트 앱이 화면을 캡처하고 원격으로 스트리밍하기 위해 화면 기록 권한이 필요합니다.
            
            1. [시스템 설정 (System Settings)] -> [개인정보 보호 및 보안 (Privacy & Security)] -> [화면 기록 (Screen Recording)]으로 이동합니다.
            2. 본 애플리케이션의 토글 스위치를 '켬'으로 전환해 주십시오.
            3. 설정을 변경한 후, 변경 사항을 적용하려면 본 애플리케이션을 완전히 종료한 후 재실행해야 합니다.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "시스템 설정 열기 (Open System Settings)")
            alert.addButton(withTitle: "나중에 (Later)")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Open Privacy & Security -> Screen Recording in System Settings
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                } else {
                    // Fallback to general system settings
                    if let fallbackUrl = URL(string: "x-apple.systempreferences:") {
                        NSWorkspace.shared.open(fallbackUrl)
                    }
                }
            }
        }
    }
}
