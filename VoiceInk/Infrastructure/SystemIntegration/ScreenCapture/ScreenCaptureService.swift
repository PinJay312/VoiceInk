import AppKit
import ApplicationServices
import CoreText
import Foundation
import os
import ScreenCaptureKit
import Vision

@MainActor
class ScreenCaptureService: ObservableObject {
    @Published var isCapturing = false
    @Published var lastCapturedText: String?

    private struct FocusedWindowHint: Sendable {
        let processID: pid_t
        let title: String?
        let frame: CGRect?
    }

    private static let captureTimeout: TimeInterval = 5.0
    private static var didStartOCRPrewarm = false
    nonisolated private static let maximumCaptureDimension: CGFloat = 2800
    nonisolated private static let focusedWindowFrameTolerance: CGFloat = 96
    nonisolated private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "ScreenCapture"
    )

    /// Warm Vision with synthetic text so first real dictation does not pay a
    /// potentially long model initialization cost. No user screen data is read.
    static func prewarmOCR() {
        guard !didStartOCRPrewarm else { return }
        didStartOCRPrewarm = true
        Task.detached(priority: .utility) {
            guard let image = Self.syntheticOCRImage() else { return }
            let started = Date()
            _ = Self.extractText(from: image)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            Self.logger.notice("OCR prewarm finished elapsedMs=\(elapsedMs, privacy: .public)")
        }
    }

    nonisolated private static func syntheticOCRImage() -> CGImage? {
        let width = 900
        let height = 180
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let font = CTFontCreateWithName("PingFang TC" as CFString, 56, nil)
        let attributes = [NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font]
        let text = NSAttributedString(string: "畫面測試詞：紫杉弧線", attributes: attributes)
        let line = CTLineCreateWithAttributedString(text)
        context.textPosition = CGPoint(x: 25, y: 60)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    static func requestScreenCapturePermissionRegistration() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        if CGRequestScreenCaptureAccess() {
            return true
        }

        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return CGPreflightScreenCaptureAccess()
        }

        return CGPreflightScreenCaptureAccess()
    }

    func captureAndExtractText() async -> String? {
        guard !isCapturing else {
            Self.logger.notice("Screen capture skipped because another capture is already running")
            return nil
        }

        isCapturing = true
        defer {
            isCapturing = false
        }

        let permissionGranted = CGPreflightScreenCaptureAccess()
        let permissionLabel = permissionGranted ? "true" : "false"
        let timeoutSeconds = Int(Self.captureTimeout)
        Self.logger.notice(
            "Screen capture started permissionGranted=\(permissionLabel, privacy: .public) timeoutSeconds=\(timeoutSeconds, privacy: .public)"
        )
        if !permissionGranted {
            Self.logger.error(
                "Screen recording permission is not granted. Enable this VoiceInk build in System Settings > Privacy & Security > Screen & System Audio Recording."
            )
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let focusedWindowHint = makeFocusedWindowHint(excluding: currentPID)
        let started = Date()

        guard
            let contextText = await Self.withTimeout(
                seconds: Self.captureTimeout,
                operation: {
                    await Self.captureAndExtractWindowText(
                        focusedWindowHint: focusedWindowHint,
                        currentPID: currentPID
                    )
                })
        else {
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            let timeoutSeconds = Int(Self.captureTimeout)
            if Date().timeIntervalSince(started) + 0.05 >= Self.captureTimeout {
                Self.logger.error(
                    "Screen capture timed out elapsedMs=\(elapsedMs, privacy: .public) limitSeconds=\(timeoutSeconds, privacy: .public)"
                )
            } else {
                Self.logger.error(
                    "Screen capture returned no context elapsedMs=\(elapsedMs, privacy: .public)"
                )
            }
            return nil
        }

        lastCapturedText = contextText
        let contextCharacters = contextText.count
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        Self.logger.notice(
            "Screen capture context ready characters=\(contextCharacters, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
        )
        return contextText
    }

    private func makeFocusedWindowHint(excluding currentPID: pid_t) -> FocusedWindowHint? {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            frontmostPID != currentPID
        else {
            return nil
        }

        var focusedTitle: String?
        var focusedFrame: CGRect?

        if AXIsProcessTrusted() {
            let appElement = AXUIElementCreateApplication(frontmostPID)
            if let focusedWindow = copyAXElementAttribute(kAXFocusedWindowAttribute, from: appElement) {
                focusedTitle = normalized(copyStringAttribute(kAXTitleAttribute, from: focusedWindow))

                if let position = copyCGPointAttribute(kAXPositionAttribute, from: focusedWindow),
                    let size = copyCGSizeAttribute(kAXSizeAttribute, from: focusedWindow)
                {
                    focusedFrame = CGRect(origin: position, size: size)
                }
            }
        }

        return FocusedWindowHint(
            processID: frontmostPID,
            title: focusedTitle,
            frame: focusedFrame
        )
    }

    private nonisolated static func captureAndExtractWindowText(
        focusedWindowHint: FocusedWindowHint?,
        currentPID: pid_t
    ) async -> String? {
        let started = Date()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windowCount = content.windows.count
            let listElapsedMs = elapsedMilliseconds(since: started)
            let permissionLabel = CGPreflightScreenCaptureAccess() ? "true" : "false"
            logger.notice(
                "SCShareableContent ready windows=\(windowCount, privacy: .public) elapsedMs=\(listElapsedMs, privacy: .public) permissionGranted=\(permissionLabel, privacy: .public)"
            )

            guard
                let window = findActiveWindow(
                    in: content.windows,
                    focusedWindowHint: focusedWindowHint,
                    currentPID: currentPID
                )
            else {
                let focusedPID = focusedWindowHint?.processID ?? -1
                logger.error(
                    "No capturable window windows=\(windowCount, privacy: .public) focusedPID=\(focusedPID, privacy: .public)"
                )
                return nil
            }

            let title = window.title ?? window.owningApplication?.applicationName ?? "Unknown"
            let appName = window.owningApplication?.applicationName ?? "Unknown"
            let frame = window.frame

            let filter = SCContentFilter(desktopIndependentWindow: window)

            let configuration = SCStreamConfiguration()
            let captureScale = captureScale(for: frame.size)
            configuration.width = max(1, Int(frame.width * captureScale))
            configuration.height = max(1, Int(frame.height * captureScale))
            let frameWidth = Int(frame.width)
            let frameHeight = Int(frame.height)
            let pixelWidth = configuration.width
            let pixelHeight = configuration.height
            logger.notice(
                "Capturing window app=\(appName, privacy: .public) title=\(title, privacy: .public) frame=\(frameWidth, privacy: .public)x\(frameHeight, privacy: .public) pixels=\(pixelWidth, privacy: .public)x\(pixelHeight, privacy: .public)"
            )

            let screenshotStarted = Date()
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            let imageWidth = cgImage.width
            let imageHeight = cgImage.height
            let screenshotElapsedMs = elapsedMilliseconds(since: screenshotStarted)
            logger.notice(
                "Screenshot captured image=\(imageWidth, privacy: .public)x\(imageHeight, privacy: .public) elapsedMs=\(screenshotElapsedMs, privacy: .public)"
            )

            var contextText = """
                Active Window: \(title)
                Application: \(appName)

                """

            let ocrStarted = Date()
            let extractedText = extractText(from: cgImage)
            let ocrCharacters = extractedText?.count ?? 0
            let ocrElapsedMs = elapsedMilliseconds(since: ocrStarted)
            logger.notice(
                "OCR finished characters=\(ocrCharacters, privacy: .public) elapsedMs=\(ocrElapsedMs, privacy: .public)"
            )
            if let extractedText, !extractedText.isEmpty {
                contextText += "Window Content:\n\(extractedText)"
            } else {
                contextText += "Window Content:\nNo text detected via OCR"
            }

            return contextText

        } catch {
            logCaptureError(error, elapsedSince: started)
            return nil
        }
    }

    private nonisolated static func logCaptureError(_ error: Error, elapsedSince started: Date) {
        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code
        let description = nsError.localizedDescription
        let elapsedMs = elapsedMilliseconds(since: started)
        logger.error(
            "Screen capture failed domain=\(domain, privacy: .public) code=\(code, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) description=\(description, privacy: .public)"
        )
        if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.userDeclined.rawValue {
            logger.error(
                "Screen recording permission denied (SCStreamErrorUserDeclined). Grant access in System Settings > Privacy & Security > Screen & System Audio Recording."
            )
        } else if nsError.domain == SCStreamErrorDomain
            && nsError.code == SCStreamError.missingEntitlements.rawValue
        {
            logger.error("Screen capture missing entitlements (SCStreamErrorMissingEntitlements).")
        }
        if !CGPreflightScreenCaptureAccess() {
            logger.error(
                "CGPreflightScreenCaptureAccess returned false. This VoiceInk build does not have Screen Recording permission."
            )
        }
    }

    private nonisolated static func elapsedMilliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private nonisolated static func findActiveWindow(
        in windows: [SCWindow],
        focusedWindowHint: FocusedWindowHint?,
        currentPID: pid_t
    ) -> SCWindow? {
        let candidates = windows.filter { window in
            guard let processID = window.owningApplication?.processID else {
                return false
            }

            return processID != currentPID && window.windowLayer == 0 && window.isOnScreen && window.frame.width > 0
                && window.frame.height > 0
        }

        guard let focusedWindowHint else {
            return candidates.first
        }

        let appWindows = candidates.filter {
            $0.owningApplication?.processID == focusedWindowHint.processID
        }

        guard !appWindows.isEmpty else {
            return candidates.first
        }

        if let focusedFrame = focusedWindowHint.frame,
            let closestWindow = closestFrameMatch(to: focusedFrame, in: appWindows),
            frameDistance(closestWindow.frame, focusedFrame) <= focusedWindowFrameTolerance
        {
            return closestWindow
        }

        if let focusedTitle = focusedWindowHint.title,
            let titledWindow = appWindows.first(where: { normalized($0.title) == focusedTitle })
        {
            return titledWindow
        }

        return appWindows.first
    }

    private nonisolated static func closestFrameMatch(to frame: CGRect, in windows: [SCWindow]) -> SCWindow? {
        windows.min {
            frameDistance($0.frame, frame) < frameDistance($1.frame, frame)
        }
    }

    private nonisolated static func frameDistance(_ first: CGRect, _ second: CGRect) -> CGFloat {
        abs(first.origin.x - second.origin.x) + abs(first.origin.y - second.origin.y)
            + abs(first.size.width - second.size.width) + abs(first.size.height - second.size.height)
    }

    private nonisolated static func captureScale(for size: CGSize) -> CGFloat {
        let longestSide = max(size.width, size.height)
        guard longestSide > 0 else {
            return 1
        }

        return min(2, maximumCaptureDimension / longestSide)
    }

    private nonisolated static func extractText(from cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hant", "en-US"]
        request.automaticallyDetectsLanguage = false

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try requestHandler.perform([request])
            guard let observations = request.results else {
                let imageWidth = cgImage.width
                let imageHeight = cgImage.height
                logger.error(
                    "Vision OCR returned no result list for image=\(imageWidth, privacy: .public)x\(imageHeight, privacy: .public)"
                )
                return nil
            }
            let text =
                observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            if text.isEmpty {
                let observationCount = observations.count
                let imageWidth = cgImage.width
                let imageHeight = cgImage.height
                logger.notice(
                    "Vision OCR found no text observations=\(observationCount, privacy: .public) image=\(imageWidth, privacy: .public)x\(imageHeight, privacy: .public)"
                )
                return nil
            }
            return text
        } catch {
            let nsError = error as NSError
            let domain = nsError.domain
            let code = nsError.code
            let description = nsError.localizedDescription
            logger.error(
                "Vision OCR failed domain=\(domain, privacy: .public) code=\(code, privacy: .public) description=\(description, privacy: .public)"
            )
            return nil
        }
    }

    private nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func copyAXElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private func copyCGPointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID(),
            AXValueGetType(value as! AXValue) == .cgPoint
        else {
            return nil
        }

        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private func copyCGSizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID(),
            AXValueGetType(value as! AXValue) == .cgSize
        else {
            return nil
        }

        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }

        return size
    }

    private nonisolated static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalized(_ text: String?) -> String? {
        Self.normalized(text)
    }
}
