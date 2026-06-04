import Foundation
import AVFoundation
import Qwen3ASR
import SpeechVAD
import MADLADTranslation
import AudioCommon

// MARK: - TranslationPipeline

/// Orchestrates live Thai speech → English text translation.
///
/// Pipeline: AVAudioEngine (mic, 16kHz mono) → SileroVAD → Qwen3ASR → MADLADTranslator
///
/// Models are lazy-loaded from HuggingFace on first use and cached locally.
/// Call `loadModels()` before `start()`, and `unloadModels()` when leaving translation mode.
@Observable @MainActor
class TranslationPipeline {

    // MARK: - Published State

    /// Whether the pipeline is actively capturing audio and processing speech.
    var isActive = false

    /// Whether all required models (ASR + VAD + MADLAD) are loaded and ready.
    var isModelLoaded = false

    /// Download/load progress (0.0–1.0) shown during model initialization.
    var modelLoadProgress: Double = 0

    /// Human-readable status during model loading (e.g. "Downloading ASR model...").
    var modelLoadStatus: String = ""

    // ASR state
    /// Partial (non-final) Thai transcription during active speech.
    var currentThaiPartial: String = ""
    /// Finalized Thai utterances from completed speech segments.
    var thaiSegments: [String] = []
    /// Whether the VAD is currently detecting speech.
    var isSpeechDetected = false

    // Translation state
    /// In-progress streaming English translation for the current segment.
    var streamingEnglish: String = ""
    /// Finalized English translations corresponding to completed segments.
    var englishSegments: [String] = []

    /// Error message for display in the UI.
    var errorMessage: String?

    // MARK: - Private

    /// Qwen3-ASR model for Thai speech recognition.
    private var asrModel: Qwen3ASRModel?
    /// Silero VAD model for voice activity detection.
    private var vadModel: SileroVADModel?
    /// MADLAD-400 translator for Thai→English streaming translation.
    private var translator: MADLADTranslator?

    /// Core Audio engine for microphone capture.
    private var audioEngine: AVAudioEngine?
    /// VAD processor wrapping the Silero model with event-based speech detection.
    private var vadProcessor: StreamingVADProcessor?
    /// Audio buffer accumulating samples between speechStart and speechEnd.
    private var audioBuffer: [Float] = []
    /// Whether speech is currently being accumulated (between start/end events).
    private var isAccumulatingSpeech = false

    /// Active translation task (cancelled when new segment arrives or pipeline stops).
    private var translationTask: Task<Void, Never>?

    // MARK: - Model Loading

    /// Download and load all required models (ASR, VAD, MADLAD).
    ///
    /// Downloads from HuggingFace on first use (~1.7GB total). Subsequent calls
    /// load from the local cache directory.
    func loadModels() async {
        guard !isModelLoaded else { return }

        errorMessage = nil
        modelLoadProgress = 0
        modelLoadStatus = "Preparing..."

        do {
            // Phase 1: Load Qwen3-ASR (0.6B, 4-bit, ~200MB)
            modelLoadStatus = "Loading ASR model..."
            let asr = try await Qwen3ASRModel.fromPretrained(
                modelId: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
                progressHandler: { [weak self] progress, status in
                    Task { @MainActor [weak self] in
                        self?.modelLoadProgress = progress * 0.3
                        self?.modelLoadStatus = "ASR: \(status)"
                    }
                }
            )
            asrModel = asr

            // Phase 2: Load Silero VAD (~2MB)
            modelLoadStatus = "Loading VAD model..."
            modelLoadProgress = 0.3
            let vad = try await SileroVADModel.fromPretrained(
                progressHandler: { [weak self] progress, status in
                    Task { @MainActor [weak self] in
                        self?.modelLoadProgress = 0.3 + progress * 0.1
                        self?.modelLoadStatus = "VAD: \(status)"
                    }
                }
            )
            vadModel = vad

            // Phase 3: Load MADLAD-400 translator (3B, int4, ~1.5GB)
            modelLoadStatus = "Loading translation model..."
            modelLoadProgress = 0.4
            let madlad = try await MADLADTranslator.fromPretrained(
                quantization: .int4,
                progressHandler: { [weak self] progress, status in
                    Task { @MainActor [weak self] in
                        self?.modelLoadProgress = 0.4 + progress * 0.6
                        self?.modelLoadStatus = "Translation: \(status)"
                    }
                }
            )
            translator = madlad

            modelLoadProgress = 1.0
            modelLoadStatus = "Ready"
            isModelLoaded = true

        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
            modelLoadStatus = "Error"
            print("TranslationPipeline model load error: \(error)")
        }
    }

    // MARK: - Start / Stop

    /// Start capturing audio from the microphone and processing speech.
    ///
    /// Requires microphone permission (will be requested automatically).
    /// Models must be loaded before calling this method.
    func start() async {
        guard isModelLoaded, let vadModel else {
            errorMessage = "Models not loaded"
            return
        }

        errorMessage = nil

        // Configure audio session
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
        } catch {
            errorMessage = "Audio session error: \(error.localizedDescription)"
            return
        }

        // Initialize VAD processor
        let vadConfig = VADConfig.sileroDefault
        vadProcessor = StreamingVADProcessor(model: vadModel, config: vadConfig)

        // Setup audio engine
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // We need 16kHz mono Float32 for the ASR model
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            errorMessage = "Cannot create target audio format"
            return
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            errorMessage = "Cannot create audio converter"
            return
        }

        // Install tap on the microphone input
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Convert to 16kHz mono
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000.0 / hwFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCount
            ) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard error == nil else { return }

            // Extract Float32 samples
            guard let channelData = convertedBuffer.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(convertedBuffer.frameLength)
            ))

            // Process on main actor for state updates
            Task { @MainActor [weak self] in
                self?.processAudioSamples(samples)
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            isActive = true
        } catch {
            errorMessage = "Failed to start audio: \(error.localizedDescription)"
        }
    }

    /// Stop audio capture and release resources.
    func stop() {
        translationTask?.cancel()
        translationTask = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        vadProcessor?.reset()
        vadProcessor = nil

        audioBuffer.removeAll()
        isAccumulatingSpeech = false
        isSpeechDetected = false
        isActive = false

        // Release audio session
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Unload all models to free memory.
    ///
    /// Call when leaving translation mode to reclaim ~1.7GB of RAM.
    func unloadModels() {
        stop()
        asrModel = nil
        vadModel = nil
        translator = nil
        isModelLoaded = false
        modelLoadProgress = 0
        modelLoadStatus = ""
    }

    /// Clear all transcription and translation history.
    func clearHistory() {
        thaiSegments.removeAll()
        englishSegments.removeAll()
        currentThaiPartial = ""
        streamingEnglish = ""
    }

    // MARK: - Audio Processing

    /// Process incoming audio samples through VAD, ASR, and translation.
    private func processAudioSamples(_ samples: [Float]) {
        guard let vadProcessor else { return }

        // Feed samples to VAD
        let events = vadProcessor.process(samples: samples)

        // Accumulate audio during speech
        if isAccumulatingSpeech {
            audioBuffer.append(contentsOf: samples)
        }

        // Process VAD events
        for event in events {
            switch event {
            case .speechStarted:
                isSpeechDetected = true
                isAccumulatingSpeech = true
                audioBuffer.removeAll()
                audioBuffer.append(contentsOf: samples)
                currentThaiPartial = "🎙️ Listening..."

            case .speechEnded(let segment):
                isSpeechDetected = false
                isAccumulatingSpeech = false

                let speechAudio = audioBuffer
                audioBuffer.removeAll()

                // Transcribe and translate the speech segment
                processCompletedSegment(audio: speechAudio, segment: segment)
            }
        }
    }

    /// Transcribe a completed speech segment and stream its translation.
    private func processCompletedSegment(audio: [Float], segment: SpeechSegment) {
        guard let asrModel, let translator else { return }
        guard !audio.isEmpty else { return }

        // Cancel any in-progress translation
        translationTask?.cancel()

        translationTask = Task { [weak self] in
            guard let self else { return }

            // Phase 1: Transcribe Thai audio
            currentThaiPartial = "⏳ Transcribing..."
            let thaiText = asrModel.transcribe(
                audio: audio,
                sampleRate: 16000,
                language: "th"
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !Task.isCancelled else { return }
            guard !thaiText.isEmpty else {
                currentThaiPartial = ""
                return
            }

            // Finalize Thai segment
            thaiSegments.append(thaiText)
            currentThaiPartial = ""

            // Phase 2: Stream translation Thai→English
            streamingEnglish = ""

            do {
                let stream = translator.translateStream(thaiText, to: "en")
                for try await token in stream {
                    guard !Task.isCancelled else { return }
                    streamingEnglish += token
                }
            } catch {
                if !Task.isCancelled {
                    print("Translation stream error: \(error)")
                }
            }

            // Finalize English segment
            guard !Task.isCancelled else { return }
            if !streamingEnglish.isEmpty {
                englishSegments.append(streamingEnglish)
            }
            streamingEnglish = ""
        }
    }
}
