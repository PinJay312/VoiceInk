import AppKit
import CoreGraphics
import Foundation
import os

final class AutoLearnKeyboardWatcher: @unchecked Sendable {
    static let shared = AutoLearnKeyboardWatcher()

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "AutoLearnKeyboard"
    )
    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.auto-learn.keyboard")

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapInstalled = false

    private struct ActiveSession {
        let originalText: String
        var currentText: String
        var cursorOffset: Int
        let processID: pid_t?
        let cmuxSurfaceRef: String?
        let startTime: DispatchTime
        var hasEdits: Bool
    }

    private var session: ActiveSession?
    private var quiescenceTimer: DispatchSourceTimer?
    private var deadlineTimer: DispatchSourceTimer?

    /// Idle gap after the latest edit before the session is committed.
    /// Long enough to move to the next word, including an IME confirmation.
    private static let quiescenceDelay: TimeInterval = 15.0
    /// Hard stop for one paste observation. Edits still present are committed.
    private static let observationDeadline: TimeInterval = 60.0

    private init() {
        installTap()
    }

    deinit {
        stopTap()
    }

    func startObservation(pastedText: String, processID: pid_t?) {
        guard !pastedText.isEmpty else { return }

        queue.async { [weak self] in
            guard let self else { return }
            self.cancelTimers()

            let newSession = ActiveSession(
                originalText: pastedText,
                currentText: pastedText,
                cursorOffset: pastedText.count,
                processID: processID,
                cmuxSurfaceRef: AutoLearnCmuxTextReader.activeSurfaceRef(processID: processID),
                startTime: .now(),
                hasEdits: false
            )
            self.session = newSession
            self.enableTap(true)
            self.logger.notice("KeyboardWatcher started observation for '\(pastedText, privacy: .public)' (processID: \(processID ?? -1))")

            let deadline = DispatchSource.makeTimerSource(queue: self.queue)
            deadline.schedule(deadline: .now() + Self.observationDeadline)
            deadline.setEventHandler { [weak self] in
                self?.handleDeadline()
            }
            deadline.resume()
            self.deadlineTimer = deadline
        }
    }

    func cancelObservation() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelTimers()
            self.session = nil
            self.enableTap(false)
        }
    }

    private func scheduleQuiescenceTimer() {
        quiescenceTimer?.cancel()
        quiescenceTimer = nil

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.quiescenceDelay)
        timer.setEventHandler { [weak self] in
            self?.handleQuiescence()
        }
        timer.resume()
        quiescenceTimer = timer
    }

    private func cancelTimers() {
        quiescenceTimer?.cancel()
        quiescenceTimer = nil
        deadlineTimer?.cancel()
        deadlineTimer = nil
    }

    private func handleQuiescence() {
        guard let current = session, current.hasEdits else { return }
        logger.notice("KeyboardWatcher quiescence reached, committing edits")
        commitSession()
    }

    private func handleDeadline() {
        guard let current = session else { return }
        if current.hasEdits {
            logger.notice("KeyboardWatcher deadline reached with edits, committing")
            commitSession()
        } else {
            logger.notice("KeyboardWatcher deadline reached with no edits, cancelling")
            cancelObservation()
        }
    }

    private func commitSession() {
        guard let current = session else { return }
        cancelTimers()
        session = nil
        enableTap(false)

        let original = current.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tracked = current.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = resolvedCorrectedText(
            original: original,
            tracked: tracked,
            processID: current.processID,
            cmuxSurfaceRef: current.cmuxSurfaceRef
        )

        guard !original.isEmpty, !corrected.isEmpty, original != corrected else {
            logger.notice("KeyboardWatcher commit: no effective diff between '\(original, privacy: .public)' and '\(corrected, privacy: .public)'")
            return
        }

        let revision = AutoLearnRevision(original: original, corrected: corrected)
        logger.notice("KeyboardWatcher committing revision: '\(original, privacy: .public)' ➔ '\(corrected, privacy: .public)'")
        Task {
            await AutoLearnService.shared.recordRevision(revision)
        }
    }

    private func installTap() {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let watcher = Unmanaged<AutoLearnKeyboardWatcher>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = watcher.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if type == .keyDown {
                watcher.handleKeyDown(event: event)
            }

            return Unmanaged.passUnretained(event)
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create keyboard delta event tap")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            logger.error("Failed to create run loop source for keyboard delta tap")
            return
        }

        self.eventTap = tap
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false) // Disabled by default until paste
        tapInstalled = true
    }

    private func enableTap(_ enable: Bool) {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: enable)
    }

    private func stopTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        tapInstalled = false
    }

    private func handleKeyDown(event: CGEvent) {
        queue.async { [weak self] in
            guard let self, var current = self.session else { return }

            let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags

            switch keyCode {
            case 51: // Backspace (Delete)
                if current.cursorOffset > 0, current.cursorOffset <= current.currentText.count {
                    let charIndex = current.currentText.index(
                        current.currentText.startIndex,
                        offsetBy: current.cursorOffset - 1
                    )
                    current.currentText.remove(at: charIndex)
                    current.cursorOffset -= 1
                    current.hasEdits = true
                    self.logger.notice("KeyboardWatcher backspace -> text='\(current.currentText, privacy: .public)' offset=\(current.cursorOffset)")
                    self.session = current
                    self.scheduleQuiescenceTimer()
                }

            case 123: // Left Arrow
                current.cursorOffset = max(0, current.cursorOffset - 1)
                self.session = current
                if current.hasEdits {
                    self.scheduleQuiescenceTimer()
                }

            case 124: // Right Arrow
                current.cursorOffset = min(current.currentText.count, current.cursorOffset + 1)
                self.session = current
                if current.hasEdits {
                    self.scheduleQuiescenceTimer()
                }

            case 36, 76: // Return / Enter confirms an IME candidate or inserts a newline.
                // Do not end the session: the user may still correct later words.
                if current.hasEdits {
                    self.logger.notice("KeyboardWatcher Return key pressed; resetting quiescence timer")
                    self.scheduleQuiescenceTimer()
                }

            default:
                // Check for Cmd+V paste replacement
                if flags.contains(.maskCommand), keyCode == 9 {
                    if let pasteboardString = NSPasteboard.general.string(forType: .string), !pasteboardString.isEmpty {
                        let insertIndex = current.currentText.index(
                            current.currentText.startIndex,
                            offsetBy: min(current.cursorOffset, current.currentText.count)
                        )
                        current.currentText.insert(contentsOf: pasteboardString, at: insertIndex)
                        current.cursorOffset += pasteboardString.count
                        current.hasEdits = true
                        self.logger.notice("KeyboardWatcher pasted text replacement -> '\(current.currentText, privacy: .public)'")
                        self.session = current
                        self.scheduleQuiescenceTimer()
                    }
                    return
                }

                // If not holding Command or Control, inspect typed characters
                if !flags.contains(.maskCommand), !flags.contains(.maskControl) {
                    var chars = [UniChar](repeating: 0, count: 16)
                    var actualLen = 0
                    event.keyboardGetUnicodeString(
                        maxStringLength: 16,
                        actualStringLength: &actualLen,
                        unicodeString: &chars
                    )
                    if actualLen > 0 {
                        let typedStr = String(utf16CodeUnits: chars, count: actualLen)
                        let nonControl = typedStr.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" }
                        if !nonControl.isEmpty {
                            let textToInsert = String(String.UnicodeScalarView(nonControl))
                            let insertIndex = current.currentText.index(
                                current.currentText.startIndex,
                                offsetBy: min(current.cursorOffset, current.currentText.count)
                            )
                            current.currentText.insert(contentsOf: textToInsert, at: insertIndex)
                            current.cursorOffset += textToInsert.count
                            current.hasEdits = true
                            self.logger.notice("KeyboardWatcher typed '\(textToInsert, privacy: .public)' -> '\(current.currentText, privacy: .public)'")
                            self.session = current
                            self.scheduleQuiescenceTimer()
                        }
                    }
                }
            }
        }
    }

    /// Prefer the focused field's full Accessibility text over the keystroke
    /// buffer, then compare that text with the original paste. A document-sized
    /// field is ignored so a whole page is not treated as one correction.
    private func resolvedCorrectedText(
        original: String,
        tracked: String,
        processID: pid_t?,
        cmuxSurfaceRef: String?
    ) -> String {
        guard let processID else { return tracked }

        let readings = AutoLearnAXTextReader().focusedReadings(processID: processID)
        let fields: [(text: String, source: String)] = readings.compactMap { reading in
            let text = reading.fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (text, "\(reading.focusSource)/\(reading.source)")
        }
        logger.notice(
            "KeyboardWatcher AX readings=\(readings.count, privacy: .public) nonempty=\(fields.count, privacy: .public)"
        )

        let referenceCount = max(original.count, tracked.count, 1)
        let plausible = fields.filter { field in
            field.text.count <= max(referenceCount * 3, referenceCount + 80)
        }
        if let best = plausible.min(by: {
            abs($0.text.count - referenceCount) < abs($1.text.count - referenceCount)
        }) {
            logger.notice(
                "KeyboardWatcher AX selected source=\(best.source, privacy: .public) characters=\(best.text.count, privacy: .public)"
            )
            if best.text != original {
                logger.notice(
                    "KeyboardWatcher resolved actual text via accessibility: '\(best.text, privacy: .public)'"
                )
                return best.text
            }
        } else if !fields.isEmpty {
            logger.notice(
                "KeyboardWatcher AX field is much larger than the paste; trying app-specific readers"
            )
        } else {
            logger.notice("KeyboardWatcher AX text unavailable; trying app-specific readers")
        }

        if let cmuxSurfaceRef,
            let cmuxText = AutoLearnCmuxTextReader.composerText(surfaceRef: cmuxSurfaceRef),
            AutoLearnCmuxTextReader.isPlausibleCorrection(original: original, candidate: cmuxText)
        {
            logger.notice(
                "KeyboardWatcher resolved actual text via cmux surface=\(cmuxSurfaceRef, privacy: .public): '\(cmuxText, privacy: .public)'"
            )
            return cmuxText
        }

        logger.notice("KeyboardWatcher app-specific text unavailable; keeping tracked text")
        return tracked
    }
}
