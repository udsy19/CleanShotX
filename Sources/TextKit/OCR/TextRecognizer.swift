import Foundation
import CoreGraphics
import Vision
import SuperScreenshotCore

/// Vision-backed text + barcode recognition. All functions are synchronous and meant to run off the main thread.
public enum TextRecognizer {

    public struct Configuration: Sendable {
        public var automaticLanguage: Bool
        /// BCP-47 codes (e.g. "en-US", "zh-Hans", "de-DE"); used when `automaticLanguage` is false.
        public var languages: [String]
        public init(automaticLanguage: Bool, languages: [String]) {
            self.automaticLanguage = automaticLanguage; self.languages = languages
        }
        /// Reads the Text Recognition preferences.
        public static func current() -> Configuration {
            Configuration(automaticLanguage: Defaults[.ocrLanguageMode] == .automatic, languages: Defaults[.ocrLanguages])
        }
    }

    public struct Result: Sendable {
        public var lines: [RecognizedLine]
        public var barcodes: [String]
    }

    // MARK: Languages

    /// Vision's supported recognition languages for the accurate recogniser (BCP-47, e.g. "en-US", "zh-Hans").
    public static let supportedLanguageCodes: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }()

    /// `(code, localized name)` pairs sorted by name, e.g. `("zh-Hans", "Chinese (Simplified)")`.
    public static func supportedLanguages() -> [(code: String, name: String)] {
        supportedLanguageCodes
            .map { (code: $0, name: displayName(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func displayName(for code: String) -> String {
        guard let name = Locale.current.localizedString(forIdentifier: code) else { return code }
        // "Chinese, Simplified" → "Chinese (Simplified)"
        if let comma = name.firstIndex(of: ",") {
            let head = name[..<comma], tail = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            return "\(head) (\(tail))"
        }
        return name
    }

    /// Maps user/legacy codes onto Vision's: exact (case-insensitive) match, Chinese region aliases
    /// (`zh-CN` → `zh-Hans`, `zh-TW`/`zh-HK` → `zh-Hant`), then same base language. Unknown codes are dropped.
    public static func normalizedLanguages(_ codes: [String], supported: [String] = supportedLanguageCodes) -> [String] {
        var out: [String] = []
        for raw in codes {
            let code = raw.replacingOccurrences(of: "_", with: "-")
            let lower = code.lowercased()
            var match = supported.first { $0.lowercased() == lower }
            if match == nil {
                let alias: String? = switch lower {
                case "zh", "zh-cn", "zh-sg", "zh-hans-cn": "zh-hans"
                case "zh-tw", "zh-hk", "zh-mo", "zh-hant-tw": "zh-hant"
                default: nil
                }
                if let alias { match = supported.first { $0.lowercased() == alias } }
            }
            if match == nil, let base = lower.split(separator: "-").first {
                match = supported.first { $0.lowercased().split(separator: "-").first == base }
            }
            if let match, !out.contains(match) { out.append(match) }
        }
        return out
    }

    /// Touches Vision once in the background so the first capture isn't slowed by model loading.
    public static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = supportedLanguageCodes }
    }

    // MARK: Recognition

    public static func recognize(in image: CGImage, configuration: Configuration) throws -> Result {
        // Vision misses tiny glyphs; small captures (typically 1x displays) are upscaled first.
        let input = image.width * image.height < 400_000 ? ImageTools.resized(image, factor: 2) : image
        let width = CGFloat(input.width), height = CGFloat(input.height)

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        if configuration.automaticLanguage {
            textRequest.automaticallyDetectsLanguage = true
        } else {
            let languages = normalizedLanguages(configuration.languages)
            if !languages.isEmpty { textRequest.recognitionLanguages = languages }
        }
        let handler = VNImageRequestHandler(cgImage: input, options: [:])
        try handler.perform([textRequest])

        let lines: [RecognizedLine] = (textRequest.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let r = VNImageRectForNormalizedRect(obs.boundingBox, Int(width), Int(height))
            return RecognizedLine(text: candidate.string, box: CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height))
        }

        var barcodes: [String] = []
        let barcodeRequest = VNDetectBarcodesRequest()
        do {
            try handler.perform([barcodeRequest])
            for obs in barcodeRequest.results ?? [] {
                if let payload = obs.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !payload.isEmpty, !barcodes.contains(payload) { barcodes.append(payload) }
            }
        } catch {
            Log.capture.error("Barcode detection failed: \(error.localizedDescription, privacy: .public)")
        }
        return Result(lines: lines, barcodes: barcodes)
    }

    /// Recognized text in reading order, followed by barcode/QR payloads that aren't already part of the text.
    static func compose(text: String, barcodes: [String]) -> String {
        let extra = barcodes.filter { !text.contains($0) }
        return ([text] + extra).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
