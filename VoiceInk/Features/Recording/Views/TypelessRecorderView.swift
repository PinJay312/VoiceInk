import SwiftUI

// MARK: - Typeless Dot Wave View

struct TypelessDotWaveView: View {
    let state: RecordingState
    let audioMeterProvider: () -> AudioMeter

    private let dotCount = 9
    private let dotDiameter: CGFloat = 3.5
    private let dotSpacing: CGFloat = 4.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.016)) { context in
            let date = context.date
            let time = date.timeIntervalSince1970
            let audioMeter = audioMeterProvider()

            HStack(spacing: dotSpacing) {
                ForEach(0..<dotCount, id: \.self) { index in
                    dotView(index: index, time: time, audioMeter: audioMeter)
                }
            }
            .frame(height: 24)
        }
    }

    @ViewBuilder
    private func dotView(index: Int, time: Double, audioMeter: AudioMeter) -> some View {
        switch state {
        case .recording:
            // Dynamic audio-reactive wave
            let centerDistance = abs(Double(index) - 4.0) / 4.0
            let centerBoost = 1.0 - (centerDistance * 0.45)
            let amplitude = max(0.0, min(1.0, pow(audioMeter.averagePower, 0.65)))
            let wave = sin(time * 12.0 + Double(index) * 0.7) * 0.5 + 0.5
            let extraHeight = CGFloat(amplitude * wave * centerBoost) * 15.0
            let height = dotDiameter + extraHeight
            let opacity = 0.45 + 0.55 * (amplitude * wave * centerBoost)

            Capsule()
                .fill(Color.white.opacity(max(0.4, min(1.0, opacity))))
                .frame(width: dotDiameter, height: height)

        case .transcribing, .enhancing:
            // Traveling sinusoidal wave animation
            let wave = sin(time * 7.0 - Double(index) * 0.7) * 0.5 + 0.5
            let yOffset = CGFloat(sin(time * 7.0 - Double(index) * 0.7)) * 3.5
            let opacity = 0.35 + 0.65 * wave

            Circle()
                .fill(Color.white.opacity(opacity))
                .frame(width: dotDiameter, height: dotDiameter)
                .offset(y: yOffset)

        case .idle, .starting, .busy:
            // At-rest subtle circular dots
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: dotDiameter, height: dotDiameter)
        }
    }
}

// MARK: - Typeless Recorder View

struct TypelessRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true

    // MARK: - Layout Constants

    private let controlBarHeight: CGFloat = 34
    private let compactWidth: CGFloat = 116
    private let expandedWidth: CGFloat = 300
    private let assistantWidth: CGFloat = 520
    private let compactCornerRadius: CGFloat = 17
    private let expandedCornerRadius: CGFloat = 14

    private var hasLiveTranscript: Bool {
        showLiveTranscript
            && stateProvider.recordingState == .recording
            && !stateProvider.partialTranscript.isEmpty
    }

    private var hasAssistantResponse: Bool {
        assistantSession.isVisible
    }

    private var shouldShowCloseButton: Bool {
        hasAssistantResponse && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    private var controlBar: some View {
        ZStack {
            TypelessDotWaveView(
                state: stateProvider.recordingState,
                audioMeterProvider: recorder.audioMeterSnapshot
            )

            if shouldShowCloseButton {
                HStack {
                    Spacer()
                    RecorderCloseButton(action: onCloseTapped)
                        .padding(.trailing, 8)
                }
            }
        }
        .frame(height: controlBarHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if !shouldShowCloseButton {
                onRecordButtonTapped()
            }
        }
    }

    private var transcriptSection: some View {
        VStack(spacing: 0) {
            if hasLiveTranscript {
                LiveTranscriptView(text: stateProvider.partialTranscript)
                Divider().background(Color.white.opacity(0.15))
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasAssistantResponse {
                AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp
                )
                Divider().background(Color.white.opacity(0.15))
            } else {
                transcriptSection
            }
            controlBar
        }
        .frame(width: hasAssistantResponse ? assistantWidth : (hasLiveTranscript ? expandedWidth : compactWidth))
        .background(
            ZStack {
                Color(red: 0.10, green: 0.10, blue: 0.11)
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.35)
            }
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: hasLiveTranscript || hasAssistantResponse ? expandedCornerRadius : compactCornerRadius,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: hasLiveTranscript || hasAssistantResponse ? expandedCornerRadius : compactCornerRadius,
                style: .continuous
            )
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)
        .animation(.easeInOut(duration: 0.25), value: hasLiveTranscript)
        .animation(.easeInOut(duration: 0.25), value: hasAssistantResponse)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
