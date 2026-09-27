import AppKit
import Foundation

enum AutoLearnCmuxTextReader {
    private static let bundleIdentifier = "com.cmuxterm.app"
    private static let binaryCandidates = [
        "/Applications/cmux.app/Contents/Resources/bin/cmux",
        "/opt/homebrew/bin/cmux",
        "/usr/local/bin/cmux",
    ]

    static func activeSurfaceRef(processID: pid_t?) -> String? {
        guard
            let processID,
            NSRunningApplication(processIdentifier: processID)?.bundleIdentifier == bundleIdentifier,
            let output = run(arguments: ["tree", "--all", "--json"]),
            let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let active = root["active"] as? [String: Any],
            let surfaceRef = active["surface_ref"] as? String,
            surfaceRef.hasPrefix("surface:")
        else {
            return nil
        }
        return surfaceRef
    }

    static func composerText(surfaceRef: String) -> String? {
        guard surfaceRef.hasPrefix("surface:") else { return nil }
        guard let screen = run(arguments: ["read-screen", "--surface", surfaceRef, "--lines", "120"])
        else { return nil }
        return extractComposerText(from: screen)
    }

    static func extractComposerText(from screen: String) -> String? {
        let lines = screen.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return nil }

        for closeIndex in lines.indices.reversed()
        where lines[closeIndex].trimmingCharacters(in: .whitespaces).hasPrefix("╰") {
            guard closeIndex > lines.startIndex else { continue }
            for openIndex in lines[..<closeIndex].indices.reversed()
            where lines[openIndex].trimmingCharacters(in: .whitespaces).hasPrefix("╭") {
                let contentLines = lines[lines.index(after: openIndex)..<closeIndex]
                var pieces: [String] = []
                var foundPromptMarker = false

                for line in contentLines {
                    guard let firstBorder = line.firstIndex(of: "│"),
                        let lastBorder = line.lastIndex(of: "│"),
                        firstBorder < lastBorder
                    else { continue }

                    var content = String(line[line.index(after: firstBorder)..<lastBorder])
                        .trimmingCharacters(in: .whitespaces)
                    if content.hasPrefix("❯") {
                        foundPromptMarker = true
                        content.removeFirst()
                        content = content.trimmingCharacters(in: .whitespaces)
                    }
                    pieces.append(content)
                }

                guard foundPromptMarker else { continue }
                let text = joinWrappedLines(pieces)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }

    static func isPlausibleCorrection(original: String, candidate: String) -> Bool {
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !candidate.isEmpty, original != candidate else { return false }
        guard candidate.count <= max(original.count * 3, original.count + 80) else { return false }

        let commonPrefix = zip(original, candidate).prefix { $0 == $1 }.count
        let remainingOriginal = original.dropFirst(commonPrefix)
        let remainingCandidate = candidate.dropFirst(commonPrefix)
        let commonSuffix = zip(remainingOriginal.reversed(), remainingCandidate.reversed())
            .prefix { $0 == $1 }.count
        let sharedEdges = commonPrefix + commonSuffix
        let shorterCount = min(original.count, candidate.count)
        return sharedEdges >= min(3, shorterCount)
            && Double(sharedEdges) / Double(shorterCount) >= 0.2
    }

    private static func joinWrappedLines(_ lines: [String]) -> String {
        var result = ""
        var pendingParagraphBreak = false

        for line in lines {
            guard !line.isEmpty else {
                if !result.isEmpty { pendingParagraphBreak = true }
                continue
            }

            if pendingParagraphBreak {
                result.append("\n")
                pendingParagraphBreak = false
            } else if let previous = result.last,
                let next = line.first,
                isASCIIWordCharacter(previous),
                isASCIIWordCharacter(next)
            {
                result.append(" ")
            }
            result.append(line)
        }
        return result
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        guard character.isASCII, let scalar = character.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func run(arguments: [String]) -> String? {
        guard let executable = binaryCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        guard finished.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
