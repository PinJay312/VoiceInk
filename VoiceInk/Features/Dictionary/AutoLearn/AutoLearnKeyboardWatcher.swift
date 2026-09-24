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
        let startTime: DispatchTime
        var hasEdits: Bool
    }

    private var session: ActiveSession?
    private var quiescenceTimer: DispatchSourceTimer?
    private var deadlineTimer: DispatchSourceTimer?

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
                startTime: .now(),
                hasEdits: false
            )
            self.session = newSession
            self.enableTap(true)
            self.logger.notice("KeyboardWatcher started observation for '\(pastedText, privacy: .public)' (processID: \(processID ?? -1))")

            // Schedule total deadline (12 seconds)
            let deadline = DispatchSource.makeTimerSource(queue: self.queue)
            deadline.schedule(deadline: .now() + 12.0)
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
        timer.schedule(deadline: .now() + 2.0)
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
        let corrected = current.currentText.trimmingCharacters(in: .whitespacesAndNewlines)

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

            case 124: // Right Arrow
                current.cursorOffset = min(current.currentText.count, current.cursorOffset + 1)
                self.session = current

            case 36, 76: // Return / Enter
                if current.hasEdits {
                    self.logger.notice("KeyboardWatcher Return key pressed with active edits")
                    self.commitSession()
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
}
