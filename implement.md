{
"task": "Implement Thai Live Speech Translation in Silo (Thai Audio → English Text)",
"description": "Add live translation mode to Silo iOS app: microphone → VoxRT Silero VAD → Qwen3-ASR (Thai speech recognition) → Llama.cpp (Thai→English translation) → dual-panel streaming UI. Focus: Thai language.",
"focus_language": "Thai",
"prerequisites": [
"Xcode project Silo (from stevederico/silo or Pavlo4242/iOS_Chat_silo)",
"iOS 18.2+ deployment target",
"Physical Apple Silicon device (iPhone 15 Pro / iPad M1+) – simulator does not support MLX or real microphone"
],
"dependencies": [
{
"name": "speech-swift",
"type": "git-submodule",
"url": "https://github.com/soniqo/speech-swift.git",
"path": "Packages/speech-swift",
"required_products": ["Qwen3ASR", "AudioCommon"],
"notes": "Qwen3ASR supports Thai (52 languages). Model downloads on first run (~400MB 4-bit)."
},
{
"name": "voxrt-silero-ios",
"type": "spm",
"url": "https://github.com/VoxRT/voxrt-silero-ios.git",
"version": "from: "0.1.3"",
"required_for": "Voice Activity Detection (Silero VAD)"
}
],
"steps": [
{
"step": 1,
"action": "Add microphone permission",
"file": "Silo/Info.plist",
"code": "<key>NSMicrophoneUsageDescription</key>\n<string>Live translation uses microphone for Thai speech recognition</string>"
},
{
"step": 2,
"action": "Add VoxRT Silero VAD Swift package",
"instructions": "In Xcode: File → Add Package Dependencies → paste https://github.com/VoxRT/voxrt-silero-ios.git, version 0.1.3 or later. Add to Silo target.",
"manual": true
},
{
"step": 3,
"action": "Add speech-swift as submodule and link Qwen3ASR",
"commands": [
"git submodule add https://github.com/soniqo/speech-swift.git Packages/speech-swift",
"git submodule update --init --recursive"
],
"xcode": "File → Add Local Package → select Packages/speech-swift; link Qwen3ASR and AudioCommon to Silo target.",
"manual": true
},
{
"step": 4,
"action": "Download VAD model (silero_vad.vxrt) and add to bundle",
"instructions": "Download from https://github.com/VoxRT/voxrt-silero-ios/releases – file silero_vad.vxrt (~1.2 MB). In Xcode, drag into project, ensure 'Copy Bundle Resources' includes it.",
"manual": true
},
{
"step": 5,
"action": "Create TranslationPipeline.swift – coordinates mic, VAD, ASR, and LLM",
"file": "Silo/UI/Components/TranslationPipeline.swift",
"code": "// TranslationPipeline.swift\nimport AVFoundation\nimport VoxrtSilero\nimport Qwen3ASR\n\n@MainActor\n@Observable\nfinal class TranslationPipeline {\n var isActive = false\n var thaiSegments: [String] = []\n var partialThai = ""\n var englishSegments: [String] = []\n var streamingEnglish = ""\n var errorMessage: String?\n private var isModelLoaded = false\n \n private var vadEngine: VoxrtSileroVadEngine?\n private var asrModel: Qwen3ASRModel?\n private var currentSession: Qwen3ASRSession?\n private var audioEngine: AVAudioEngine?\n private var translationTask: Task<Void, Never>?\n private weak var llamaState: LlamaState?\n \n // MARK: - Model Loading\n func loadModels() async {\n guard !isModelLoaded else { return }\n do {\n // Load VAD model from bundle\n vadEngine = try VoxrtSileroVadEngine.fromBundleResource(\n named: "silero_vad",\n extension: "vxrt",\n config: VoxrtSileroConfig(\n onsetThreshold: 0.5,\n offsetThreshold: 0.35,\n minSilenceMs: 100\n )\n )\n \n // Load Qwen3-ASR model (Thai capable) – downloads on first run\n asrModel = try await Qwen3ASRModel.fromPretrained()\n isModelLoaded = true\n } catch {\n errorMessage = "Model load failed: \(error.localizedDescription)"\n }\n }\n \n // MARK: - Pipeline Control\n func start(llama: LlamaState) async throws {\n guard let asr = asrModel, let vad = vadEngine else {\n throw PipelineError.modelNotLoaded\n }\n self.llamaState = llama\n \n // Reset state\n thaiSegments = []\n englishSegments = []\n partialThai = ""\n streamingEnglish = ""\n \n // Setup audio engine\n audioEngine = AVAudioEngine()\n let inputNode = audioEngine!.inputNode\n let nativeFormat = inputNode.outputFormat(forBus: 0)\n \n // Target format: 16kHz mono Int16 (required by VAD and Qwen3-ASR)\n guard let converterFormat = AVAudioFormat(\n commonFormat: .pcmFormatInt16,\n sampleRate: 16000,\n channels: 1,\n interleaved: false\n ) else { throw PipelineError.formatConversionFailed }\n \n guard let converter = AVAudioConverter(from: nativeFormat, to: converterFormat) else {\n throw PipelineError.converterInitFailed\n }\n \n // Create ASR session for Thai\n currentSession = try asr.createSession(language: "th")\n vad.reset()\n \n // Install tap\n inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in\n guard let self else { return }\n \n // Convert to 16kHz Int16\n guard let converted = self.convertTo16kHzInt16(buffer, converter: converter) else { return }\n guard let channelData = converted.int16ChannelData?[0] else { return }\n let frameCount = Int(converted.frameLength)\n let pcmSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))\n \n Task.detached(priority: .userInitiated) { [weak self] in\n await self?.processAudioChunk(pcmSamples)\n }\n }\n \n try audioEngine!.start()\n isActive = true\n }\n \n private func processAudioChunk(_ samples: [Int16]) async {\n guard let asr = currentSession, let vad = vadEngine else { return }\n \n do {\n // 1. VAD to detect speech boundaries\n let vadEvents = try vad.processPcm(samples)\n var shouldFinalize = false\n for event in vadEvents {\n switch event {\n case .speechOnset:\n await MainActor.run { self.partialThai = "" }\n case .speechOffset:\n shouldFinalize = true\n }\n }\n \n // 2. ASR transcription (streaming)\n let asrResults = try await asr.pushAudio(samples.map { Float($0) / 32768.0 })\n \n await MainActor.run {\n for result in asrResults {\n if result.isFinal || shouldFinalize {\n if !result.text.isEmpty {\n thaiSegments.append(result.text)\n partialThai = ""\n translateUtterance(result.text)\n }\n } else {\n partialThai = result.text\n }\n }\n }\n } catch {\n await MainActor.run { errorMessage = error.localizedDescription }\n }\n }\n \n private func convertTo16kHzInt16(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) -> AVAudioPCMBuffer? {\n let targetFormat = AVAudioFormat(\n commonFormat: .pcmFormatInt16,\n sampleRate: 16000,\n channels: 1,\n interleaved: false\n )!\n let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 1024)\n var error: NSError?\n converter.convert(to: converted!, error: &error) { , outStatus in\n outStatus.pointee = .haveData\n return buffer\n }\n return converted\n }\n \n private func translateUtterance( thaiText: String) {\n translationTask?.cancel()\n translationTask = Task { [weak self] in\n guard let llama = self?.llamaState else { return }\n await MainActor.run { self?.streamingEnglish = "" }\n \n await llama.translateChunk(\n thaiText,\n onToken: { token in\n Task { @MainActor in\n self?.streamingEnglish += token\n }\n },\n onComplete: { fullText in\n Task { @MainActor in\n self?.englishSegments.append(fullText)\n self?.streamingEnglish = ""\n }\n }\n )\n }\n }\n \n func stop() {\n translationTask?.cancel()\n audioEngine?.stop()\n audioEngine?.inputNode.removeTap(onBus: 0)\n audioEngine = nil\n currentSession = nil\n vadEngine?.reset()\n isActive = false\n }\n}\n\nenum PipelineError: LocalizedError {\n case modelNotLoaded, formatConversionFailed, converterInitFailed\n}"
},
{
"step": 6,
"action": "Add translation method to LlamaState",
"file": "Silo/UI/LlamaState.swift",
"code": "// Add inside LlamaState class\nprivate let translationSystemPrompt = """\nYou are a Thai to English translator. Output ONLY the English translation, no extra text. Be concise and natural.\n"""\n\nfunc translateChunk(_ thaiText: String, onToken: @escaping (String) -> Void, onComplete: @escaping (String) -> Void) async {\n let messages: [[String: String]] = [\n ["role": "system", "content": translationSystemPrompt],\n ["role": "user", "content": thaiText]\n ]\n var fullTranslation = ""\n \n // Assumes LibLlama actor has a complete method. For token streaming, modify LibLlama to support AsyncStream.\n // For MVP, use complete() and send full translation at once.\n let result = await actor.complete(messages: messages)\n fullTranslation = result\n // Simulate streaming by sending whole text as a single token (or split into words for better UX)\n let words = fullTranslation.split(separator: " ")\n for word in words {\n onToken(String(word) + " ")\n try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay between words\n }\n onComplete(fullTranslation)\n}"
},
{
"step": 7,
"action": "Create TranslationView.swift – dual-panel UI",
"file": "Silo/UI/TranslationView.swift",
"code": "// TranslationView.swift\nimport SwiftUI\n\nstruct TranslationView: View {\n @State private var pipeline = TranslationPipeline()\n @ObservedObject var llamaState: LlamaState\n \n var body: some View {\n VStack(spacing: 0) {\n // Header\n HStack {\n Label("🇹🇭 Thai", systemImage: "mic")\n Spacer()\n if pipeline.isActive {\n HStack(spacing: 4) {\n Circle().fill(.red).frame(width: 8, height: 8)\n Text("LIVE").font(.caption.bold())\n }\n }\n Spacer()\n Label("🇬🇧 English", systemImage: "text.bubble")\n }\n .padding()\n .background(.ultraThinMaterial)\n \n // Dual panels\n GeometryReader { geo in\n VStack(spacing: 1) {\n // Thai panel\n ScrollViewReader { proxy in\n ScrollView {\n VStack(alignment: .leading, spacing: 8) {\n ForEach(pipeline.thaiSegments.indices, id: \.self) { idx in\n Text(pipeline.thaiSegments[idx])\n .padding(8)\n .background(Color.orange.opacity(0.1))\n .cornerRadius(8)\n }\n if !pipeline.partialThai.isEmpty {\n Text(pipeline.partialThai)\n .foregroundColor(.gray)\n .italic()\n .id("partial")\n }\n }\n .padding()\n }\n .onChange(of: pipeline.partialThai) { _ in\n withAnimation { proxy.scrollTo("partial", anchor: .bottom) }\n }\n }\n .frame(height: geo.size.height * 0.45)\n \n Divider()\n \n // English panel\n ScrollViewReader { proxy in\n ScrollView {\n VStack(alignment: .leading, spacing: 8) {\n ForEach(pipeline.englishSegments.indices, id: \.self) { idx in\n Text(pipeline.englishSegments[idx])\n .padding(8)\n .background(Color.blue.opacity(0.1))\n .cornerRadius(8)\n }\n if !pipeline.streamingEnglish.isEmpty {\n Text(pipeline.streamingEnglish)\n .foregroundColor(.gray)\n .id("streaming")\n }\n }\n .padding()\n }\n .onChange(of: pipeline.streamingEnglish) { _ in\n withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }\n }\n }\n .frame(height: geo.size.height * 0.45)\n }\n }\n \n // Control button\n Button {\n Task {\n if pipeline.isActive {\n pipeline.stop()\n } else {\n try? await pipeline.start(llama: llamaState)\n }\n }\n } label: {\n Label(\n pipeline.isActive ? "Stop Translation" : "Start Translation",\n systemImage: pipeline.isActive ? "stop.circle.fill" : "mic.circle.fill"\n )\n .frame(maxWidth: .infinity)\n .padding()\n .background(pipeline.isActive ? Color.red : Color.accentColor)\n .foregroundColor(.white)\n .cornerRadius(12)\n }\n .padding()\n .disabled(pipeline.errorMessage != nil)\n }\n .task { await pipeline.loadModels() }\n .alert("Error", isPresented: .constant(pipeline.errorMessage != nil), presenting: pipeline.errorMessage) { _ in\n Button("OK") { pipeline.errorMessage = nil }\n } message: { msg in\n Text(msg)\n }\n }\n}"
},
{
"step": 8,
"action": "Add navigation link in ContentView",
"file": "Silo/UI/ContentView.swift",
"code": "// In ContentView.swift, add to the toolbar\n.toolbar {\n ToolbarItemGroup(placement: .navigationBarTrailing) {\n // ... existing buttons ...\n NavigationLink(destination: TranslationView(llamaState: llamaState)) {\n Image(systemName: "waveform.and.mic")\n .accessibilityLabel("Live Translation")\n }\n }\n}"
}
],
"verification": [
"Build the app on a physical Apple Silicon device (not simulator).",
"Open Translation view – models will download (~400MB Qwen3-ASR + ~1.2MB VAD) on first launch.",
"Tap 'Start Translation', grant microphone permission.",
"Speak Thai sentences. Thai panel shows partial transcripts as you speak, then final utterance. English panel shows translated text shortly after (may appear word-by-word).",
"Test multiple sentences – pipeline handles utterance boundaries automatically via VAD.",
"Stop translation – audio engine releases microphone.",
"Check memory usage in Xcode Instruments – both Qwen3-ASR and LLM should fit within ~1-2GB.",
"Verify existing chat functionality unchanged."
],
"notes": [
"Qwen3ASRModel.fromPretrained() downloads model from Hugging Face on first use. Add progress UI if desired.",
"Translation uses LlamaState.complete – token streaming simulated with word-by-word delay. For true streaming, modify LibLlama to return AsyncStream.",
"VAD model file 'silero_vad.vxrt' must be in bundle. If missing, VAD init will fail.",
"If speech-swift API differs (e.g., createSession language parameter), consult speech-swift documentation.",
"For future higher Thai accuracy, replace Qwen3-ASR with WhisperKit + typhoon-whisper-turbo (batch mode, higher latency).",
"Python-based whisper_streaming (ufal) is not used – this is a pure Swift/iOS implementation."
]
}