#!/usr/bin/env swift
import Foundation
import Vision

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("store-assets/source")
let locales = ["en-US", "de-DE", "es-ES", "ar-SA", "ja-JP", "zh-Hans", "zh-Hant", "fr-FR"]
let hangul = try! NSRegularExpression(pattern: "[\\u1100-\\u11FF\\u3130-\\u318F\\uAC00-\\uD7A3]")
var failures: [String] = []

for locale in locales {
    let localeRoot = root.appendingPathComponent(locale)
    let files = (FileManager.default.enumerator(at: localeRoot, includingPropertiesForKeys: nil)?
        .allObjects as? [URL] ?? [])
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.path < $1.path }

    for file in files {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["ko-KR", "en-US"]
        try VNImageRequestHandler(url: file).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if hangul.firstMatch(in: text, range: range) != nil {
            failures.append("\(file.path): \(text)")
        }
    }
}

if !failures.isEmpty {
    FileHandle.standardError.write((failures.joined(separator: "\n") + "\n").data(using: .utf8)!)
    exit(1)
}

print("OK: non-Korean localized sources contain no recognized Korean text")
