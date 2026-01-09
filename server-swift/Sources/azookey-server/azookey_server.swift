import KanaKanjiConverterModule
import Foundation
import ffi

@MainActor var dicdataStore: DicdataStore!
@MainActor var converter: KanaKanjiConverter!
@MainActor var composingText = ComposingText()

@MainActor var execURL = URL(filePath: "")
@MainActor var logFileHandle: FileHandle?

// Memory directory for learning data
@MainActor var memoryURL: URL!

// Store last conversion result for learning
@MainActor var lastConversionResult: [Candidate] = []

// MARK: - Reusable FFI Buffers (to prevent memory leaks)
// These buffers are reused across calls instead of allocating new memory each time
// Using raw UnsafeMutablePointer for stable memory addresses (Swift Arrays can move)

// Buffer for simple string returns (max 1KB should be plenty for composing text)
let stringBufferSize = 1024
@MainActor var stringBuffer: UnsafeMutablePointer<CChar> = .allocate(capacity: stringBufferSize)

// Buffers for candidate list (max 100 candidates, each with 3 strings of max 256 chars)
let maxCandidates = 100
let maxStringLen = 256

// Raw pointer arrays for stable memory addresses
@MainActor var candidateTextBuffers: [UnsafeMutablePointer<CChar>] = []
@MainActor var candidateSubtextBuffers: [UnsafeMutablePointer<CChar>] = []
@MainActor var candidateHiraganaBuffers: [UnsafeMutablePointer<CChar>] = []
@MainActor var candidatePtrs: [UnsafeMutablePointer<FFICandidate>] = []
@MainActor var candidatePtrArray: UnsafeMutablePointer<UnsafeMutablePointer<FFICandidate>?>? = nil
@MainActor var buffersInitialized = false

// Helper to copy string to buffer safely
@MainActor func copyToBuffer(_ str: String, buffer: UnsafeMutablePointer<CChar>, maxLen: Int) {
    let cString = str.utf8CString
    let copyLen = min(cString.count, maxLen - 1)
    for i in 0..<copyLen {
        buffer[i] = cString[i]
    }
    buffer[copyLen] = 0 // null terminate
}

// Initialize all candidate buffers once with stable raw pointers
@MainActor func initCandidateBuffers() {
    guard !buffersInitialized else { return }
    buffersInitialized = true

    candidatePtrArray = .allocate(capacity: maxCandidates)

    for i in 0..<maxCandidates {
        // Allocate stable string buffers
        let textBuf = UnsafeMutablePointer<CChar>.allocate(capacity: maxStringLen)
        let subtextBuf = UnsafeMutablePointer<CChar>.allocate(capacity: maxStringLen)
        let hiraganaBuf = UnsafeMutablePointer<CChar>.allocate(capacity: maxStringLen)

        // Initialize to empty strings
        textBuf[0] = 0
        subtextBuf[0] = 0
        hiraganaBuf[0] = 0

        candidateTextBuffers.append(textBuf)
        candidateSubtextBuffers.append(subtextBuf)
        candidateHiraganaBuffers.append(hiraganaBuf)

        // Allocate candidate struct
        let candidatePtr = UnsafeMutablePointer<FFICandidate>.allocate(capacity: 1)
        candidatePtr.pointee = FFICandidate(text: textBuf, subtext: subtextBuf, hiragana: hiraganaBuf, correspondingCount: 0)
        candidatePtrs.append(candidatePtr)
        candidatePtrArray![i] = candidatePtr
    }
}

// Set to true to enable debug logging (causes slowdown)
let DEBUG_LOGGING_ENABLED = false

@MainActor func debugLog(_ message: String) {
    guard DEBUG_LOGGING_ENABLED else { return }
    let logMessage = "[\(Date())] \(message)\n"
    print(logMessage, terminator: "")

    // Also write to file
    if let data = logMessage.data(using: .utf8) {
        logFileHandle?.write(data)
        // Removed synchronize() - was causing major slowdown
    }
}

@MainActor func initLogFile() {
    let logPath = URL(filePath: "G:/Projects/azooKey-Windows/swift_debug.log")
    _ = FileManager.default.createFile(atPath: logPath.path, contents: nil)
    logFileHandle = try? FileHandle(forWritingTo: logPath)
}
@MainActor var config: [String : Any] = [
    "enable": false,
    "profile": "",
]

// User dictionary entries: [reading: [words]]
@MainActor var userDictionary: [String: [String]] = [:]

// Cache for ConvertRequestOptions to avoid recreating on every keystroke
@MainActor var cachedOptions: ConvertRequestOptions?
@MainActor var cachedTextReplacer: TextReplacer?

@MainActor func getOptions(context: String = "") -> ConvertRequestOptions {
    // Create TextReplacer only once
    if cachedTextReplacer == nil {
        cachedTextReplacer = .init {
            return execURL.appendingPathComponent("EmojiDictionary").appendingPathComponent("emoji_all_E15.1.txt")
        }
    }

    return ConvertRequestOptions(
        requireJapanesePrediction: true,
        requireEnglishPrediction: false,
        keyboardLanguage: .ja_JP,
        learningType: .inputAndOutput,
        maxMemoryCount: 65536,
        memoryDirectoryURL: memoryURL,
        sharedContainerURL: memoryURL,
        textReplacer: cachedTextReplacer!,
        specialCandidateProviders: nil,
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

// Helper to get total input count from ComposingCount for FFI interface
func getInputCount(_ count: ComposingCount) -> Int {
    switch count {
    case .inputCount(let n):
        return n
    case .surfaceCount(let n):
        return n
    case .composite(let a, let b):
        return getInputCount(a) + getInputCount(b)
    }
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
    initLogFile()
    let path = String(cString: path)
    execURL = URL(filePath: path)
    debugLog("Initialize called, path: \(path)")

    // Set up memory directory for learning data
    if let appDataPath = ProcessInfo.processInfo.environment["APPDATA"] {
        memoryURL = URL(filePath: appDataPath)
            .appendingPathComponent("Azookey")
            .appendingPathComponent("memory")
        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: memoryURL,
            withIntermediateDirectories: true
        )
        print("Memory directory: \(memoryURL.path)")
    } else {
        // Fallback to local directory
        memoryURL = execURL.appendingPathComponent("memory")
        try? FileManager.default.createDirectory(
            at: memoryURL,
            withIntermediateDirectories: true
        )
    }

    load_config()

    // Initialize DicdataStore and KanaKanjiConverter with new API
    let dictionaryURL = execURL.appendingPathComponent("Dictionary")
    debugLog("Dictionary URL: \(dictionaryURL.path)")

    // Check if dictionary files exist
    let loudsPath = dictionaryURL.appendingPathComponent("louds")
    let cbPath = dictionaryURL.appendingPathComponent("cb")
    let fm = FileManager.default
    debugLog("Louds path exists: \(fm.fileExists(atPath: loudsPath.path))")
    debugLog("CB path exists: \(fm.fileExists(atPath: cbPath.path))")

    // List some files in louds directory
    if let files = try? fm.contentsOfDirectory(atPath: loudsPath.path) {
        debugLog("Louds directory has \(files.count) files")
        // Show first 10 files
        for file in files.prefix(10) {
            debugLog("  - \(file)")
        }
        // Check for Japanese-named files (looking for katakana ニ which should exist)
        let hasNiFile = files.contains { $0.hasPrefix("ニ") }
        debugLog("Has ニ.louds files: \(hasNiFile)")
        let japaneseFiles = files.filter { $0.first?.isLetter == true && !$0.first!.isASCII }
        debugLog("Japanese-named files count: \(japaneseFiles.count)")
        for file in japaneseFiles.prefix(5) {
            debugLog("  Japanese file: \(file)")
        }
        // Try to access ニ.louds directly
        let niLoudsPath = loudsPath.appendingPathComponent("ニ.louds")
        debugLog("ニ.louds path: \(niLoudsPath.path)")
        debugLog("ニ.louds exists: \(fm.fileExists(atPath: niLoudsPath.path))")
    }

    dicdataStore = DicdataStore(dictionaryURL: dictionaryURL, preloadDictionary: true)
    debugLog("DicdataStore created")
    converter = KanaKanjiConverter(dicdataStore: dicdataStore)
    debugLog("KanaKanjiConverter created")

    // Test conversion with hiragana directly
    composingText.insertAtCursorPosition("a", inputStyle: .roman2kana)
    let testResult = converter.requestCandidates(composingText, options: getOptions())
    debugLog("Test conversion for 'a': \(testResult.mainResults.count) results")
    for (idx, candidate) in testResult.mainResults.prefix(3).enumerated() {
        debugLog("  Test result[\(idx)]: text='\(candidate.text)'")
    }
    composingText = ComposingText()

    // Test with nihon (にほん) - double n to complete ん
    var testText2 = ComposingText()
    testText2.insertAtCursorPosition("nihonn", inputStyle: .roman2kana)
    debugLog("Test input 'nihonn': convertTarget='\(testText2.convertTarget)'")
    let testResult2 = converter.requestCandidates(testText2, options: getOptions())
    debugLog("Test conversion for 'nihonn': \(testResult2.mainResults.count) results")
    for (idx, candidate) in testResult2.mainResults.prefix(10).enumerated() {
        debugLog("  nihonn result[\(idx)]: text='\(candidate.text)'")
    }

    // Test with direct hiragana input
    var testText3 = ComposingText()
    testText3.insertAtCursorPosition("にほん", inputStyle: .direct)
    debugLog("Test direct 'にほん': convertTarget='\(testText3.convertTarget)'")
    let testResult3 = converter.requestCandidates(testText3, options: getOptions())
    debugLog("Test direct にほん: \(testResult3.mainResults.count) results")
    for (idx, candidate) in testResult3.mainResults.prefix(10).enumerated() {
        debugLog("  direct にほん result[\(idx)]: text='\(candidate.text)'")
    }

    debugLog("Initialization complete")
}

@_silgen_name("AppendText")
@MainActor public func append_text(
    input: UnsafePointer<CChar>,
    cursorPtr: UnsafeMutablePointer<Int>
) -> UnsafeMutablePointer<CChar> {
    let inputString = String(cString: input)
    composingText.insertAtCursorPosition(inputString, inputStyle: .roman2kana)

    cursorPtr.pointee = composingText.convertTargetCursorPosition
    copyToBuffer(composingText.convertTarget, buffer: stringBuffer, maxLen: stringBufferSize)
    return stringBuffer
}

@_silgen_name("RemoveText")
@MainActor public func remove_text(
    cursorPtr: UnsafeMutablePointer<Int>
) -> UnsafeMutablePointer<CChar> {
    composingText.deleteBackwardFromCursorPosition(count: 1)

    cursorPtr.pointee = composingText.convertTargetCursorPosition
    copyToBuffer(composingText.convertTarget, buffer: stringBuffer, maxLen: stringBufferSize)
    return stringBuffer
}

@_silgen_name("MoveCursor")
@MainActor public func move_cursor(
    offset: Int32,
    cursorPtr: UnsafeMutablePointer<Int>
) -> UnsafeMutablePointer<CChar> {
    let cursor = composingText.moveCursorFromCursorPosition(count: Int(offset))
    print("offset: \(offset), cursor: \(cursor)")

    cursorPtr.pointee = cursor
    copyToBuffer(composingText.convertTarget, buffer: stringBuffer, maxLen: stringBufferSize)
    return stringBuffer
}

@_silgen_name("ClearText")
@MainActor public func clear_text() {
    print("[CLEAR] Clearing all text and calling stopComposition()")
    composingText = ComposingText()
    // Reset converter internal state to prevent slowdown from accumulated caches
    converter.stopComposition()
}

// Track conversion times for performance debugging
@MainActor var conversionCount = 0
@MainActor var totalConversionTime: Double = 0

@_silgen_name("GetComposedText")
@MainActor public func get_composed_text(lengthPtr: UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<UnsafeMutablePointer<FFICandidate>?> {
    // Initialize buffers on first call
    initCandidateBuffers()

    let hiragana = composingText.convertTarget
    debugLog("GetComposedText called, hiragana: '\(hiragana)'")
    let contextString = (config["context"] as? String) ?? ""
    let options = getOptions(context: contextString)

    // Time the conversion for performance debugging
    let startTime = Date()
    let converted = converter.requestCandidates(composingText, options: options)
    let elapsed = Date().timeIntervalSince(startTime) * 1000  // ms

    conversionCount += 1
    totalConversionTime += elapsed

    // Log timing to file for analysis
    let perfLog = "[PERF] Conv #\(conversionCount): \(String(format: "%.1f", elapsed))ms, avg: \(String(format: "%.1f", totalConversionTime / Double(conversionCount)))ms, len: \(hiragana.count)\n"
    if let data = perfLog.data(using: .utf8) {
        let perfPath = URL(filePath: "G:/Projects/azooKey-Windows/perf.log")
        if let handle = try? FileHandle(forWritingTo: perfPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: perfPath.path, contents: data)
        }
    }

    debugLog("mainResults count: \(converted.mainResults.count)")

    // Store conversion result for learning
    lastConversionResult = converted.mainResults

    var candidateIndex = 0

    // Helper to add a candidate using reusable buffers (stable raw pointers)
    func addCandidate(text: String, subtext: String, reading: String, count: Int32) {
        guard candidateIndex < maxCandidates else { return }

        // Copy strings to pre-allocated stable buffers
        copyToBuffer(text, buffer: candidateTextBuffers[candidateIndex], maxLen: maxStringLen)
        copyToBuffer(subtext, buffer: candidateSubtextBuffers[candidateIndex], maxLen: maxStringLen)
        copyToBuffer(reading, buffer: candidateHiraganaBuffers[candidateIndex], maxLen: maxStringLen)

        // Update only the correspondingCount (pointers are already set during init)
        candidatePtrs[candidateIndex].pointee.correspondingCount = count

        candidateIndex += 1
    }

    // Add user dictionary entries first (if hiragana matches a reading)
    if let userWords = userDictionary[hiragana] {
        for word in userWords {
            addCandidate(text: word, subtext: "", reading: hiragana, count: Int32(hiragana.count))
        }
    }

    // Also check for partial matches (user dictionary reading is prefix of input)
    for (reading, words) in userDictionary {
        if hiragana.hasPrefix(reading) && reading != hiragana {
            for word in words {
                let remaining = String(hiragana.dropFirst(reading.count))
                addCandidate(text: word, subtext: remaining, reading: reading, count: Int32(reading.count))
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
            dateStrings.append("\(year)\(String(format: "%02d", month))\(String(format: "%02d", day))")
            dateStrings.append("\(month)月\(day)日(\(weekday))")
            dateStrings.append("\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))")
            dateStrings.append("\(year)年\(month)月\(day)日")
            dateStrings.append("\(year)年\(month)月\(day)日(\(weekday))")
            dateStrings.append("\(month)月\(day)日")
        case "あした":
            if let tomorrow = cal.date(byAdding: .day, value: 1, to: now) {
                let year = cal.component(.year, from: tomorrow)
                let month = cal.component(.month, from: tomorrow)
                let day = cal.component(.day, from: tomorrow)
                let weekday = weekdays[cal.component(.weekday, from: tomorrow)]
                dateStrings.append("\(year)\(String(format: "%02d", month))\(String(format: "%02d", day))")
                dateStrings.append("\(month)月\(day)日(\(weekday))")
                dateStrings.append("\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))")
                dateStrings.append("\(year)年\(month)月\(day)日")
                dateStrings.append("\(year)年\(month)月\(day)日(\(weekday))")
                dateStrings.append("\(month)月\(day)日")
            }
        case "きのう":
            if let yesterday = cal.date(byAdding: .day, value: -1, to: now) {
                let year = cal.component(.year, from: yesterday)
                let month = cal.component(.month, from: yesterday)
                let day = cal.component(.day, from: yesterday)
                let weekday = weekdays[cal.component(.weekday, from: yesterday)]
                dateStrings.append("\(year)\(String(format: "%02d", month))\(String(format: "%02d", day))")
                dateStrings.append("\(month)月\(day)日(\(weekday))")
                dateStrings.append("\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))")
                dateStrings.append("\(year)年\(month)月\(day)日")
                dateStrings.append("\(year)年\(month)月\(day)日(\(weekday))")
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
            addCandidate(text: dateStr, subtext: "", reading: hiragana, count: Int32(hiragana.count))
        }
    }

    for i in 0..<converted.mainResults.count {
        let candidate = converted.mainResults[i]
        let text = constructCandidateString(candidate: candidate, hiragana: hiragana)
        let composingCount = candidate.composingCount

        var afterComposingText = composingText
        afterComposingText.prefixComplete(composingCount: composingCount)
        let subtext = afterComposingText.convertTarget

        addCandidate(text: text, subtext: subtext, reading: hiragana, count: Int32(getInputCount(composingCount)))
    }

    lengthPtr.pointee = candidateIndex

    return candidatePtrArray!
}

@_silgen_name("ShrinkText")
@MainActor public func shrink_text(
    offset: Int32
) -> UnsafeMutablePointer<CChar>  {
    var afterComposingText = composingText
    afterComposingText.prefixComplete(composingCount: .inputCount(Int(offset)))
    composingText = afterComposingText

    // Reset converter state when text is confirmed
    print("[SHRINK] offset=\(offset), remaining='\(composingText.convertTarget)', calling stopComposition()")
    converter.stopComposition()

    copyToBuffer(composingText.convertTarget, buffer: stringBuffer, maxLen: stringBufferSize)
    return stringBuffer
}

@_silgen_name("SetContext")
@MainActor public func set_context(
    context: UnsafePointer<CChar>
) {
    let contextString = String(cString: context)
    config["context"] = contextString
}

// MARK: - FFI Memory Deallocation Functions
// These functions allow Rust to properly free memory allocated by Swift

@_silgen_name("FreeString")
public func free_string(ptr: UnsafeMutablePointer<CChar>?) {
    // strdup/_strdup uses C's malloc, so we use free()
    ptr?.deallocate()
}

@_silgen_name("FreeComposedTextResult")
public func free_composed_text_result(
    result: UnsafeMutablePointer<UnsafeMutablePointer<FFICandidate>?>?,
    length: Int
) {
    guard let result = result else { return }

    for i in 0..<length {
        if let candidatePtr = result[i] {
            // Free strdup'd strings using free() since strdup uses malloc
            free(candidatePtr.pointee.text)
            free(candidatePtr.pointee.subtext)
            free(candidatePtr.pointee.hiragana)
            // Free the FFICandidate pointer
            candidatePtr.deallocate()
        }
    }
    // Free the outer array
    result.deallocate()
}

// MARK: - History Learning Functions

@_silgen_name("LearnCandidate")
@MainActor public func learn_candidate(candidateIndex: Int32) {
    // Validate index
    guard candidateIndex >= 0,
          Int(candidateIndex) < lastConversionResult.count else {
        print("[LEARN] Invalid candidate index: \(candidateIndex), available: \(lastConversionResult.count)")
        return
    }

    let candidate = lastConversionResult[Int(candidateIndex)]
    print("[LEARN] Learning candidate[\(candidateIndex)]: '\(candidate.text)'")

    // Update learning data
    converter.setCompletedData(candidate)
    converter.updateLearningData(candidate)
    converter.commitUpdateLearningData()

    print("[LEARN] Learning committed successfully")
}

@_silgen_name("ResetLearningMemory")
@MainActor public func reset_learning_memory() {
    print("[LEARN] Resetting all learning memory")
    converter.resetMemory()
}