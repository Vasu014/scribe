import Foundation
import WhisperKit

/// Removes Whisper's special-token vocabulary from decoded segment text
/// (SPEC §4.2).
///
/// Whisper's decoder emits control tokens interleaved with words —
/// `<|startoftranscript|>`, a language tag such as `<|en|>`, the task token
/// `<|transcribe|>`, timestamp tokens at 0.02 s granularity (`<|0.00|>`),
/// and `<|endoftext|>`. WhisperKit only omits them from
/// `TranscriptionSegment.text` when `DecodingOptions.skipSpecialTokens` is
/// set (it defaults to `false`), so a mis-set option — or a future model
/// whose vocabulary WhisperKit does not recognise — would otherwise write
/// raw tokens into the store, exports, the fusion prompt, and the
/// hallucination-check haystack.
///
/// This type is the defensive second line: every `TranscriptSegment` text
/// passes through `strip(_:)` before it leaves TranscribeKit, so no
/// downstream reader can ever see a token even if the decode options change.
///
/// Timestamp tokens carry no information that is lost here: segment
/// start/end offsets come from `WhisperHypothesis.startSeconds` /
/// `endSeconds`, which WhisperKit derives from the timestamp *token ids*
/// (`SegmentSeeker`), never by parsing the text.
public enum WhisperSpecialTokens {

    /// Matches the Whisper token grammar only — `<|` + a known control name,
    /// a Whisper language code, or a `SS.ss` timestamp + `|>`. Deliberately
    /// NOT `<\|[^|]*\|>`: a speaker saying something that contains `<|` (or a
    /// transcript of code) must survive untouched.
    private static let tokenPattern: NSRegularExpression = {
        // The full Whisper control vocabulary. `nocaptions`/`startoflm`
        // appear in older/derived vocabularies; harmless to match either way.
        let controlTokens = [
            "endoftext",
            "startoftranscript",
            "startofprev",
            "startoflm",
            "nospeech",
            "nocaptions",
            "notimestamps",
            "transcribe",
            "translate",
        ]
        // Language tags come from WhisperKit's own table, so the set stays
        // exact as the SDK adds languages. Filtered to plain lowercase codes
        // so the alternation can never contain a regex metacharacter.
        let languageTokens = Constants.languages.values
            .filter { $0.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil }
            .sorted()
        // Timestamps: 0.02 s granularity, always two decimals (`<|29.98|>`).
        let timestamp = #"\d{1,4}\.\d{2}"#
        let alternation = (controlTokens + languageTokens + [timestamp]).joined(separator: "|")
        // Safe to force: every alternative is either a literal identifier or
        // the fixed timestamp sub-pattern above.
        return try! NSRegularExpression(pattern: #"<\|(?:\#(alternation))\|>"#)
    }()

    /// Returns `text` with every Whisper special token removed and the
    /// whitespace they leave behind normalised.
    ///
    /// Whitespace handling: runs of whitespace collapse to a single space and
    /// the result is trimmed, so `"<|startoftranscript|><|0.00|> Hello."`
    /// yields `"Hello."` rather than a leading-space segment, and a token
    /// removed mid-sentence does not leave a double space. Text that is
    /// nothing but tokens yields `""` — callers drop those segments instead
    /// of persisting a blank row.
    ///
    /// - Parameter text: Raw decoded text from a Whisper engine.
    /// - Returns: Token-free, whitespace-normalised text.
    public static func strip(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let withoutTokens = tokenPattern.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
        // Collapses runs and trims both ends in one pass.
        return withoutTokens.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
