import SwiftUI

// MARK: - TranslationView

/// Dual-panel streaming Thai → English translation interface.
///
/// Shows Thai transcriptions (top) and English translations (bottom)
/// with real-time streaming, VAD indicators, and model download progress.
struct TranslationView: View {
    @State private var pipeline = TranslationPipeline()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            translationHeader

            // Content
            if !pipeline.isModelLoaded {
                modelLoadingView
            } else {
                translationPanels
            }

            // Controls
            controlBar
        }
        .background(Color(.systemBackground))
        .task {
            if !pipeline.isModelLoaded {
                await pipeline.loadModels()
            }
        }
        .onDisappear {
            pipeline.stop()
        }
    }

    // MARK: - Header

    private var translationHeader: some View {
        HStack {
            Text("🇹🇭 Thai → 🇬🇧 English")
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()

            if pipeline.isActive {
                HStack(spacing: 6) {
                    Circle()
                        .fill(pipeline.isSpeechDetected ? Color.red : Color.green)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .fill(Color.red.opacity(0.4))
                                .frame(width: 16, height: 16)
                                .opacity(pipeline.isSpeechDetected ? 1 : 0)
                                .scaleEffect(pipeline.isSpeechDetected ? 1.5 : 1)
                                .animation(.easeInOut(duration: 0.5).repeatForever(), value: pipeline.isSpeechDetected)
                        )
                    Text("LIVE")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Model Loading View

    private var modelLoadingView: some View {
        VStack(spacing: 20) {
            Spacer()

            if let error = pipeline.errorMessage {
                // Error state
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)

                Text("Model Loading Failed")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button("Retry") {
                    Task { await pipeline.loadModels() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                // Loading state
                VStack(spacing: 16) {
                    ProgressView(value: pipeline.modelLoadProgress) {
                        Text("Downloading Models")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    } currentValueLabel: {
                        Text(pipeline.modelLoadStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)

                    Text("\(Int(pipeline.modelLoadProgress * 100))%")
                        .font(.title2)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundColor(.accentColor)

                    Text("~1.7 GB total • First time only")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Translation Panels

    private var translationPanels: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Thai panel (top half)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("🇹🇭 Thai")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(pipeline.thaiSegments.enumerated()), id: \.offset) { index, segment in
                                    Text(segment)
                                        .font(.body)
                                        .padding(.horizontal)
                                        .id("thai-\(index)")
                                }

                                if !pipeline.currentThaiPartial.isEmpty {
                                    Text(pipeline.currentThaiPartial)
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                        .italic()
                                        .padding(.horizontal)
                                        .id("thai-partial")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onChange(of: pipeline.thaiSegments.count) { _, _ in
                            withAnimation {
                                proxy.scrollTo("thai-\(pipeline.thaiSegments.count - 1)", anchor: .bottom)
                            }
                        }
                        .onChange(of: pipeline.currentThaiPartial) { _, _ in
                            withAnimation {
                                proxy.scrollTo("thai-partial", anchor: .bottom)
                            }
                        }
                    }
                }
                .frame(height: geometry.size.height / 2)
                .background(Color(.secondarySystemBackground).opacity(0.5))

                Divider()

                // English panel (bottom half)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("🇬🇧 English")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(pipeline.englishSegments.enumerated()), id: \.offset) { index, segment in
                                    Text(segment)
                                        .font(.body)
                                        .padding(.horizontal)
                                        .id("en-\(index)")
                                }

                                if !pipeline.streamingEnglish.isEmpty {
                                    HStack(spacing: 0) {
                                        Text(pipeline.streamingEnglish)
                                            .font(.body)
                                            .foregroundColor(.accentColor)

                                        // Typing cursor
                                        Rectangle()
                                            .fill(Color.accentColor)
                                            .frame(width: 2, height: 16)
                                            .opacity(cursorOpacity)
                                            .animation(.easeInOut(duration: 0.5).repeatForever(), value: cursorOpacity)
                                    }
                                    .padding(.horizontal)
                                    .id("en-streaming")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onChange(of: pipeline.englishSegments.count) { _, _ in
                            withAnimation {
                                proxy.scrollTo("en-\(pipeline.englishSegments.count - 1)", anchor: .bottom)
                            }
                        }
                        .onChange(of: pipeline.streamingEnglish) { _, _ in
                            withAnimation {
                                proxy.scrollTo("en-streaming", anchor: .bottom)
                            }
                        }
                    }
                }
                .frame(height: geometry.size.height / 2)
            }
        }
    }

    @State private var cursorOpacity: Double = 1.0

    // MARK: - Control Bar

    private var controlBar: some View {
        VStack(spacing: 8) {
            if let error = pipeline.errorMessage, pipeline.isModelLoaded {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }

            HStack(spacing: 16) {
                // Clear history
                Button {
                    pipeline.clearHistory()
                } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .disabled(!pipeline.isModelLoaded || pipeline.thaiSegments.isEmpty)

                Spacer()

                // Main start/stop button
                Button {
                    Task {
                        if pipeline.isActive {
                            pipeline.stop()
                        } else {
                            await pipeline.start()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pipeline.isActive ? "stop.fill" : "mic.fill")
                        Text(pipeline.isActive ? "Stop" : "Start")
                            .fontWeight(.semibold)
                    }
                    .frame(minWidth: 120)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 24)
                    .background(pipeline.isActive ? Color.red : Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                .disabled(!pipeline.isModelLoaded)

                Spacer()

                // Unload models
                Button {
                    pipeline.unloadModels()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .disabled(pipeline.isActive)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
        .onAppear {
            // Start cursor blink
            cursorOpacity = 0
        }
    }
}

#Preview {
    TranslationView()
}
