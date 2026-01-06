import KanaKanjiConverterModule
import Foundation
import ffi

@MainActor let converter = KanaKanjiConverter()
@MainActor var composingText = ComposingText()

@MainActor var execURL = URL(filePath: "")
@MainActor var config: [String : Any] = [
    "enable": false,
    "profile": "",
]

// User dictionary entries: [reading: [words]]
@MainActor var userDictionary: [String: [String]] = [:]

@MainActor func getOptions(context: String = "") -> ConvertRequestOptions {
    return ConvertRequestOptions(
        requireJapanesePrediction: true,
        requireEnglishPrediction: false,
        keyboardLanguage: .ja_JP,
        learningType: .nothing,
        dictionaryResourceURL: execURL.appendingPathComponent("Dictionary"),
        memoryDirectoryURL: URL(filePath: "./test"),
        sharedContainerURL: URL(filePath: "./test"),
        textReplacer: .init {
            return execURL.appendingPathComponent("EmojiDictionary").appendingPathComponent("emoji_all_E15.1.txt")
        },
        // zenzai
        zenzaiMode: config["enable"] as! Bool ? .on(
            weight: execURL.appendingPathComponent("zenz.gguf"),
            inferenceLimit: 1,
            requestRichCandidates: true,
            personalizationMode: nil,
            versionDependentMode: .v3(
                .init(
                    profile: config["profile"] as! String,
                    leftSideContext: context
                )
            )
        ) : .off,
        preloadDictionary: true,
        metadata: .init(versionString: "Azookey for Windows")
    )
}

class SimpleComposingText {
    init(text: String, cursor: Int) {
        self.text = UnsafeMutablePointer<CChar>(mutating: text.utf8String)!
        self.cursor = cursor
    }

    var text: UnsafeMutablePointer<CChar>
    var cursor: Int
}

struct SComposingText {
    var text: UnsafeMutablePointer<CChar>
    var cursor: Int
}

func constructCandidateString(candidate: Candidate, hiragana: String) -> String {
    var remainingHiragana = hiragana
    var result = ""
    
    for data in candidate.data {
        if remainingHiragana.count < data.ruby.count {
            result += remainingHiragana
            break
        }
        remainingHiragana.removeFirst(data.ruby.count)
        result += data.word
    }
    
    return result
}

@_silgen_name("LoadConfig")
@MainActor public func load_config() {
    if let appDataPath = ProcessInfo.processInfo.environment["APPDATA"] {
        let settingsPath = URL(filePath: appDataPath).appendingPathComponent("Azookey/settings.json")

        do {
            let data = try Data(contentsOf: settingsPath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Load Zenzai config
                if let zenzaiDict = json["zenzai"] as? [String: Any] {
                    if let enableValue = zenzaiDict["enable"] as? Bool {
                        config["enable"] = enableValue
                    }

                    if let profileValue = zenzaiDict["profile"] as? String {
                        config["profile"] = profileValue
                    }
                }

                // Load user dictionary
                if let dictConfig = json["dictionary"] as? [String: Any],
                   let entries = dictConfig["entries"] as? [[String: String]] {
                    userDictionary = [:]
                    for entry in entries {
                        if let word = entry["word"], let reading = entry["reading"] {
                            if userDictionary[reading] == nil {
                                userDictionary[reading] = []
                            }
                            userDictionary[reading]?.append(word)
                        }
                    }
                    print("Loaded \(entries.count) user dictionary entries")
                }
            }
        } catch {
            print("Failed to read settings: \(error)")
        }
    }
}

@_silgen_name("Initialize")
@MainActor public func initialize(
    path: UnsafePointer<CChar>,
    use_zenzai: Bool
) {
    let path = String(cString: path)
    execURL = URL(filePath: path)

    load_config()

    composingText.insertAtCursorPosition("a", inputStyle: .roman2kana)
    converter.requestCandidates(composingText, options: getOptions())
    composingText = ComposingText()
}

@_silgen_name("AppendText")
@MainActor public func append_text(
    input: UnsafePointer<CChar>,
    cursorPtr: UnsafeMutablePointer<Int>
) -> UnsafeMutablePointer<CChar> {
    let inputString = String(cString: input)
    composingText.insertAtCursorPosition(inputString, inputStyle: .roman2kana)

    cursorPtr.pointee = composingText.convertTargetCursorPosition    
    return _strdup(composingText.convertTarget)!
}

@_silgen_name("RemoveText")
@MainActor public func remove_text(
    cursorPtr: UnsafeMutablePointer<Int>
) -> UnsafeMutablePointer<CChar> {
    composingText.deleteBackwardFromCursorPosition(count: 1)

    cursorPtr.pointee = composingText.convertTargetCursorPosition
    return _strdup(composingText.convertTarget)!
}

@_silgen_name("MoveCursor")
@MainActor public func move_cursor(
    offset: Int32,
    cursorPtr: UnsafeMutablePointer<Int>
) -> UnsafeMutablePointer<CChar> {
    let previousCursor = composingText.convertTargetCursorPosition
    let cursor = composingText.moveCursorFromCursorPosition(count: Int(offset))
    print("offset: \(offset), cursor: \(cursor)")

    cursorPtr.pointee = cursor
    return _strdup(composingText.convertTarget)!
}

@_silgen_name("ClearText")
@MainActor public func clear_text() {
    composingText = ComposingText()
}

func to_list_pointer(_ list: [FFICandidate]) -> UnsafeMutablePointer<UnsafeMutablePointer<FFICandidate>?> {
    let pointer = UnsafeMutablePointer<UnsafeMutablePointer<FFICandidate>?>.allocate(capacity: list.count)
    for (i, item) in list.enumerated() {
        pointer[i] = UnsafeMutablePointer<FFICandidate>.allocate(capacity: 1)
        pointer[i]?.pointee = item
    }
    return pointer
}

@_silgen_name("GetComposedText")
@MainActor public func get_composed_text(lengthPtr: UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<UnsafeMutablePointer<FFICandidate>?> {
    let hiragana = composingText.convertTarget
    let contextString = (config["context"] as? String) ?? ""
    let options = getOptions(context: contextString)
    let converted = converter.requestCandidates(composingText, options: options)
    var result: [FFICandidate] = []

    // Add user dictionary entries first (if hiragana matches a reading)
    if let userWords = userDictionary[hiragana] {
        for word in userWords {
            let text = strdup(word)
            let hiraganaPtr = strdup(hiragana)
            let correspondingCount = Int32(hiragana.count)
            let subtext = strdup("")

            result.append(FFICandidate(text: text, subtext: subtext, hiragana: hiraganaPtr, correspondingCount: correspondingCount))
        }
    }

    // Also check for partial matches (user dictionary reading is prefix of input)
    for (reading, words) in userDictionary {
        if hiragana.hasPrefix(reading) && reading != hiragana {
            for word in words {
                let text = strdup(word)
                let hiraganaPtr = strdup(reading)
                let correspondingCount = Int32(reading.count)
                // Calculate remaining text after this reading
                let remaining = String(hiragana.dropFirst(reading.count))
                let subtext = strdup(remaining)

                result.append(FFICandidate(text: text, subtext: subtext, hiragana: hiraganaPtr, correspondingCount: correspondingCount))
            }
        }
    }

    // Date/time conversion using Calendar components (no DateFormatter)
    let dateKeywords = ["きょう", "あした", "きのう", "いま", "にちじ"]
    if dateKeywords.contains(hiragana) {
        let cal = Calendar.current
        let now = Date()
        var dateStrings: [String] = []

        // Japanese weekday names (Sunday=1 in Calendar)
        let weekdays = ["", "日", "月", "火", "水", "木", "金", "土"]

        switch hiragana {
        case "きょう":
            let year = cal.component(.year, from: now)
            let month = cal.component(.month, from: now)
            let day = cal.component(.day, from: now)
            let weekday = weekdays[cal.component(.weekday, from: now)]
            dateStrings.append("\(year)年\(month)月\(day)日")
            dateStrings.append("\(month)月\(day)日(\(weekday))")
            dateStrings.append("\(year)年\(month)月\(day)日(\(weekday))")
            dateStrings.append("\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))")
            dateStrings.append("\(month)月\(day)日")
        case "あした":
            if let tomorrow = cal.date(byAdding: .day, value: 1, to: now) {
                let year = cal.component(.year, from: tomorrow)
                let month = cal.component(.month, from: tomorrow)
                let day = cal.component(.day, from: tomorrow)
                let weekday = weekdays[cal.component(.weekday, from: tomorrow)]
                dateStrings.append("\(year)年\(month)月\(day)日")
                dateStrings.append("\(month)月\(day)日(\(weekday))")
                dateStrings.append("\(year)年\(month)月\(day)日(\(weekday))")
                dateStrings.append("\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))")
                dateStrings.append("\(month)月\(day)日")
            }
        case "きのう":
            if let yesterday = cal.date(byAdding: .day, value: -1, to: now) {
                let year = cal.component(.year, from: yesterday)
                let month = cal.component(.month, from: yesterday)
                let day = cal.component(.day, from: yesterday)
                let weekday = weekdays[cal.component(.weekday, from: yesterday)]
                dateStrings.append("\(year)年\(month)月\(day)日")
                dateStrings.append("\(month)月\(day)日(\(weekday))")
                dateStrings.append("\(year)年\(month)月\(day)日(\(weekday))")
                dateStrings.append("\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))")
                dateStrings.append("\(month)月\(day)日")
            }
        case "いま":
            let hour = cal.component(.hour, from: now)
            let minute = cal.component(.minute, from: now)
            dateStrings.append("\(String(format: "%02d", hour)):\(String(format: "%02d", minute))")
            dateStrings.append("\(hour)時\(minute)分")
        case "にちじ":
            let year = cal.component(.year, from: now)
            let month = cal.component(.month, from: now)
            let day = cal.component(.day, from: now)
            let hour = cal.component(.hour, from: now)
            let minute = cal.component(.minute, from: now)
            dateStrings.append("\(year)年\(month)月\(day)日 \(String(format: "%02d", hour)):\(String(format: "%02d", minute))")
        default:
            break
        }

        for dateStr in dateStrings {
            result.append(FFICandidate(
                text: strdup(dateStr),
                subtext: strdup(""),
                hiragana: strdup(hiragana),
                correspondingCount: Int32(hiragana.count)
            ))
        }
    }

    for i in 0..<converted.mainResults.count {
        let candidate = converted.mainResults[i]

        let text = strdup(constructCandidateString(candidate: candidate, hiragana: hiragana))
        let hiragana = strdup(hiragana)
        let correspondingCount = candidate.correspondingCount

        var afterComposingText = composingText
        afterComposingText.prefixComplete(correspondingCount: correspondingCount)
        let subtext = strdup(afterComposingText.convertTarget)

        result.append(FFICandidate(text: text, subtext: subtext, hiragana: hiragana, correspondingCount: Int32(correspondingCount)))
    }

    lengthPtr.pointee = result.count

    return to_list_pointer(result)
}

@_silgen_name("ShrinkText")
@MainActor public func shrink_text(
    offset: Int32
) -> UnsafeMutablePointer<CChar>  {
    var afterComposingText = composingText
    afterComposingText.prefixComplete(correspondingCount: Int(offset))
    composingText = afterComposingText

    return _strdup(composingText.convertTarget)!
}

@_silgen_name("SetContext")
@MainActor public func set_context(
    context: UnsafePointer<CChar>
) {
    let contextString = String(cString: context)
    config["context"] = contextString
}