import AVFoundation
import CoreMedia
import Foundation
import Speech

public enum SpeechEngineError: LocalizedError {
  case unsupportedLocale(String)
  case noAudioFormat
  case unreadableAudio(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedLocale(let id): "Speech recognition on this Mac does not support '\(id)'."
    case .noAudioFormat: "Could not determine an audio format for the speech model."
    case .unreadableAudio(let reason): "Could not read the audio file: \(reason)"
    }
  }
}

public enum SpeechLocales {
  /// Resolves "ja", "ja-JP", "en_US"… to a locale the on-device model supports.
  public static func resolve(_ identifier: String?) async throws -> Locale {
    let id = (identifier?.isEmpty == false ? identifier! : Locale.current.identifier)
    if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) {
      return locale
    }
    throw SpeechEngineError.unsupportedLocale(id)
  }

  public static func supported() async -> [String] {
    await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
  }

  public static func installed() async -> [String] {
    await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
  }

  /// Downloads the model for the module's locale the first time it is used.
  static func ensureAssets(for module: SpeechTranscriber, onDownload: (() -> Void)? = nil) async throws {
    guard await AssetInventory.status(forModules: [module]) != .installed,
      let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
    else { return }
    onDownload?()
    try await request.downloadAndInstall()
  }
}

/// Live transcription of a PCM stream. Results are reported as volatile ("partial") and final.
public final class StreamTranscriber: @unchecked Sendable {
  public enum Event: Sendable {
    case downloadingModel(locale: String)
    case ready(locale: String)
    case partial(String)
    case final(String, start: Double, end: Double)
    case error(String)
  }

  private let lock = NSLock()
  private var analyzer: SpeechAnalyzer?
  private var continuation: AsyncStream<AnalyzerInput>.Continuation?
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var analyzerFormat: AVAudioFormat?
  private var resultsTask: Task<Void, Never>?
  private let onEvent: @Sendable (Event) -> Void

  public init(onEvent: @escaping @Sendable (Event) -> Void) {
    self.onEvent = onEvent
  }

  /// Prepares the model. `sampleRate` is the rate of the 16-bit mono PCM the client will send.
  public func start(locale identifier: String?, sampleRate: Double = 16000) async throws {
    await finish()
    let locale = try await SpeechLocales.resolve(identifier)
    let transcriber = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: [])
    try await SpeechLocales.ensureAssets(for: transcriber) { [onEvent] in
      onEvent(.downloadingModel(locale: locale.identifier))
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
      let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
    else { throw SpeechEngineError.noAudioFormat }

    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.prepareToAnalyze(in: format)
    try await analyzer.start(inputSequence: stream)

    lock.withLock {
      self.analyzer = analyzer
      self.continuation = continuation
      self.inputFormat = input
      self.analyzerFormat = format
      self.converter = format == input ? nil : AVAudioConverter(from: input, to: format)
    }
    let onEvent = self.onEvent
    resultsTask = Task {
      do {
        for try await result in transcriber.results {
          let text = String(result.text.characters)
          if result.isFinal {
            onEvent(.final(text, start: result.range.start.seconds, end: result.range.end.seconds))
          } else {
            onEvent(.partial(text))
          }
        }
      } catch {
        onEvent(.error(error.localizedDescription))
      }
    }
    onEvent(.ready(locale: locale.identifier))
  }

  /// Feeds 16-bit little-endian mono PCM.
  public func append(pcm16 data: Data) {
    lock.lock()
    let continuation = self.continuation
    let converter = self.converter
    let inputFormat = self.inputFormat
    let analyzerFormat = self.analyzerFormat
    lock.unlock()
    guard let continuation, let inputFormat, let analyzerFormat else { return }

    let frames = AVAudioFrameCount(data.count / 2)
    guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else { return }
    input.frameLength = frames
    data.withUnsafeBytes { raw in
      _ = memcpy(input.int16ChannelData![0], raw.baseAddress!, Int(frames) * 2)
    }
    guard let converter else {
      continuation.yield(AnalyzerInput(buffer: input))
      return
    }
    let capacity = AVAudioFrameCount(Double(frames) * analyzerFormat.sampleRate / inputFormat.sampleRate) + 64
    guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return input
    }
    if error == nil, output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
  }

  /// Finalizes everything received so far and waits for the last results.
  public func finish() async {
    let (continuation, analyzer, task) = lock.withLock {
      let values = (self.continuation, self.analyzer, self.resultsTask)
      self.continuation = nil
      self.analyzer = nil
      self.resultsTask = nil
      self.converter = nil
      return values
    }
    continuation?.finish()
    if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    _ = await task?.value
  }
}

/// Transcribes a whole audio file (wav, m4a, mp3, aiff, caf… anything AVAudioFile can read).
public enum FileTranscriber {
  public struct Result: Sendable {
    public var text: String
    public var locale: String
    public var duration: Double
    public var segments: [TranscriptSegment]
  }

  public static func transcribe(fileURL: URL, locale identifier: String?) async throws -> Result {
    let locale = try await SpeechLocales.resolve(identifier)
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    try await SpeechLocales.ensureAssets(for: transcriber)

    let file: AVAudioFile
    do {
      file = try AVAudioFile(forReading: fileURL)
    } catch {
      throw SpeechEngineError.unreadableAudio(error.localizedDescription)
    }
    let duration = Double(file.length) / file.processingFormat.sampleRate

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let collector = Task { () throws -> [TranscriptSegment] in
      var segments: [TranscriptSegment] = []
      for try await result in transcriber.results where result.isFinal {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          segments.append(TranscriptSegment(start: result.range.start.seconds, end: result.range.end.seconds, text: text))
        }
      }
      return segments
    }
    if let end = try await analyzer.analyzeSequence(from: file) {
      try await analyzer.finalizeAndFinish(through: end)
    } else {
      await analyzer.cancelAndFinishNow()
    }
    let segments = try await collector.value
    return Result(
      text: joinSegments(segments.map(\.text), locale: locale),
      locale: locale.identifier,
      duration: duration,
      segments: segments)
  }

  /// Languages written without spaces between sentences are joined directly.
  public static func joinSegments(_ texts: [String], locale: Locale) -> String {
    let noSpace = ["ja", "zh", "th", "lo", "km", "my", "yue"]
    let separator = noSpace.contains(locale.language.languageCode?.identifier ?? "") ? "" : " "
    return texts.joined(separator: separator)
  }
}
