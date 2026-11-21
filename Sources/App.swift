import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
import Speech
import Photos
import UIKit

@main
struct NarrativeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

enum AIMode: String, CaseIterable {
    case fast = "Fast"
    case balanced = "Balanced"
    case max = "Max"
    
    var modelName: String {
        switch self {
        case .fast, .balanced: return "gemini-2.5-flash"
        case .max: return "gemini-2.5-pro"
        }
    }
}

struct TimelineProject: Codable, Identifiable {
    var id = UUID()
    var versionLabel: String = "v1"
    var aspect_ratio: String
    var clips: [TimelineClip]
    var overlays: [TextOverlay]
    var auto_captions: Bool
    var assistant_reply: String?
    
    enum CodingKeys: String, CodingKey {
        case aspect_ratio, clips, overlays, auto_captions, assistant_reply
    }
}

struct TimelineClip: Codable, Identifiable {
    var id = UUID()
    var clip_index: Int
    var start_seconds: Double
    var end_seconds: Double
    var speed: Double
    var label: String?
    
    enum CodingKeys: String, CodingKey {
        case clip_index, start_seconds, end_seconds, speed, label
    }
}

struct TextOverlay: Codable, Identifiable {
    var id = UUID()
    var text: String
    var start_seconds: Double
    var end_seconds: Double
    var position: String
    
    enum CodingKeys: String, CodingKey {
        case text, start_seconds, end_seconds, position
    }
}

class NarrativeEngine {
    func transcribeClip(url: URL) async -> String {
        let authStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        guard authStatus == .authorized, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return "" }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                guard let result = result, result.isFinal else {
                    if error != nil { cont.resume(returning: "") }
                    return
                }
                let words = result.bestTranscription.segments.map {
                    "[\(String(format: "%.1f", $0.timestamp))s: \($0.substring)]"
                }.joined(separator: " ")
                cont.resume(returning: words)
            }
        }
    }
    
    func generateCaptions(from url: URL) async -> [TextOverlay] {
        let authStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        guard authStatus == .authorized, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return [] }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                guard let result = result, result.isFinal else {
                    if error != nil { cont.resume(returning: []) }
                    return
                }
                var overlays: [TextOverlay] = []
                var chunk: [String] = []
                var start: Double = 0
                for seg in result.bestTranscription.segments {
                    if chunk.isEmpty { start = seg.timestamp }
                    chunk.append(seg.substring)
                    if chunk.count >= 4 {
                        overlays.append(TextOverlay(text: chunk.joined(separator: " "), start_seconds: start, end_seconds: seg.timestamp + seg.duration, position: "bottom"))
                        chunk.removeAll()
                    }
                }
                if !chunk.isEmpty, let last = result.bestTranscription.segments.last {
                    overlays.append(TextOverlay(text: chunk.joined(separator: " "), start_seconds: start, end_seconds: last.timestamp + last.duration, position: "bottom"))
                }
                cont.resume(returning: overlays)
            }
        }
    }
    
    func updateTimeline(prompt: String, mode: AIMode, clipDurations: [Double], transcripts: [String], referenceImage: UIImage?, currentTimeline: TimelineProject?, apiKey: String) async throws -> TimelineProject {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: "https://googleapis.com\(mode.modelName):generateContent?key=\(cleanKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let currentJson = (try? String(data: JSONEncoder().encode(currentTimeline), encoding: .utf8)) ?? "None"
        let clipsSummary = clipDurations.enumerated().map { idx, dur in
            let speech = idx < transcripts.count && !transcripts[idx].isEmpty ? " | Speech: \(transcripts[idx])" : ""
            return "Clip \(idx) (\(String(format: "%.1f", dur))s)\(speech)"
        }.joined(separator: "\n")
        
        let fullPrompt = """
        You are Narrative, an AI-first professional video editor. You can search spoken dialogue inside clips, match visual styles from any reference image shown by the user, cut tight montages, change aspect ratios, adjust speeds, and add titles or captions.
        Output ONLY valid JSON matching this exact schema (no markdown):
        {
          "aspect_ratio": "9:16" | "16:9" | "1:1" | "4:5",
          "clips": [{"clip_index": 0, "start_seconds": 0.0, "end_seconds": 5.0, "speed": 1.0, "label": "Intro Hook"}],
          "overlays": [{"text": "Title Text", "start_seconds": 0.0, "end_seconds": 2.5, "position": "center"}],
          "auto_captions": true,
          "assistant_reply": "Short summary of edits made"
        }
        Available Footage:\n\(clipsSummary)
        Current Timeline:\n\(currentJson)
        User Prompt:\n\(prompt)
        """
        
        var parts: [[String: Any]] = [["text": fullPrompt]]
        if let img = referenceImage, let jpegData = img.jpegData(compressionQuality: 0.7) {
            parts.append([
                "inline_data": [
                    "mime_type": "image/jpeg",
                    "data": jpegData.base64EncodedString()
                ]
            ])
        }
        
        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": ["responseMimeType": "application/json"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let apiError = (raw?["error"] as? [String: Any])?["message"] as? String {
            throw NSError(domain: "Gemini", code: 400, userInfo: [NSLocalizedDescriptionKey: apiError])
        }
        guard let candidates = raw?["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let respParts = content["parts"] as? [[String: Any]],
              let text = respParts.first?["text"] as? String,
              let jsonData = text.data(using: .utf8) else {
            throw NSError(domain: "Narrative", code: 401, userInfo: [NSLocalizedDescriptionKey: "Could not read AI reply"])
        }
        return try JSONDecoder().decode(TimelineProject.self, from: jsonData)
    }
    
    func renderProject(sourceURLs: [URL], project: TimelineProject) async throws -> URL {
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Narrative", code: 1)
        }
        
        var cursor = CMTime.zero
        for clip in project.clips {
            guard clip.clip_index < sourceURLs.count else { continue }
            let asset = AVURLAsset(url: sourceURLs[clip.clip_index])
            let duration = try await asset.load(.duration)
            let start = CMTime(seconds: max(0, clip.start_seconds), preferredTimescale: 600)
            let end = CMTime(seconds: min(clip.end_seconds, duration.seconds), preferredTimescale: 600)
            let range = CMTimeRange(start: start, end: end)
            if range.duration.seconds <= 0 { continue }
            
            if let vTrack = try await asset.loadTracks(withMediaType: .video).first {
                try compVideo.insertTimeRange(range, of: vTrack, at: cursor)
            }
            if let aTrack = try await asset.loadTracks(withMediaType: .audio).first {
                try compAudio.insertTimeRange(range, of: aTrack, at: cursor)
            }
            let speed = max(0.25, min(clip.speed, 4.0))
            let scaledDur = CMTimeMultiplyByFloat64(range.duration, multiplier: 1.0 / speed)
            let insertedRange = CMTimeRange(start: cursor, duration: range.duration)
            compVideo.scaleTimeRange(insertedRange, toDuration: scaledDur)
            compAudio.scaleTimeRange(insertedRange, toDuration: scaledDur)
            cursor = CMTimeAdd(cursor, scaledDur)
        }
        
        var allOverlays = project.overlays
        if project.auto_captions, let firstURL = sourceURLs.first {
            let captions = await generateCaptions(from: firstURL)
            allOverlays.append(contentsOf: captions)
        }
        
Use code with caution.
let renderSize = sizeForAspectRatio(project.aspect_ratio)
let videoComp = AVMutableVideoComposition()
videoComp.renderSize = renderSize
videoComp.frameDuration = CMTime(value: 1, timescale: 30)
let instruction = AVMutableVideoCompositionInstruction()
instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
instruction.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)]
videoComp.instructions = [instruction]
let parentLayer = CALayer()
let videoLayer = CALayer()
parentLayer.frame = CGRect(origin: .zero, size: renderSize)
videoLayer.frame = CGRect(origin: .zero, size: renderSize)
parentLayer.addSublayer(videoLayer)
for overlay in allOverlays {
let textLayer = CATextLayer()
textLayer.string = overlay.text
textLayer.fontSize = 48
textLayer.foregroundColor = UIColor.white.cgColor
textLayer.backgroundColor = UIColor.black.withAlphaComponent(0.75).cgColor
textLayer.alignmentMode = .center
textLayer.cornerRadius = 14
textLayer.opacity = 0.0
let yPos: CGFloat = overlay.position == "top" ? renderSize.height * 0.80 :
overlay.position == "bottom" ? renderSize.height * 0.14 : renderSize.height * 0.48
textLayer.frame = CGRect(x: 50, y: yPos, width: renderSize.width - 100, height: 76)
let showAnim = CABasicAnimation(keyPath: "opacity")
showAnim.fromValue = 0.0
showAnim.toValue = 1.0
showAnim.beginTime = AVCoreAnimationBeginTimeAtZero + overlay.start_seconds
showAnim.duration = 0.05
showAnim.fillMode = .forwards
showAnim.isRemovedOnCompletion = false
let hideAnim = CABasicAnimation(keyPath: "opacity")
hideAnim.fromValue = 1.0
hideAnim.toValue = 0.0
hideAnim.beginTime = AVCoreAnimationBeginTimeAtZero + overlay.end_seconds
hideAnim.duration = 0.05
hideAnim.fillMode = .forwards
hideAnim.isRemovedOnCompletion = false
textLayer.add(showAnim, forKey: "show")
textLayer.add(hideAnim, forKey: "hide")
parentLayer.addSublayer(textLayer)
}
videoComp.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("narrative_(UUID().uuidString).mp4")
guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
throw NSError(domain: "Narrative", code: 2)
}
exporter.outputURL = outputURL
exporter.outputFileType = .mp4
exporter.videoComposition = videoComp
await exporter.export()
return outputURL
}
func saveToCameraRoll(_ url: URL) async throws {
try await PHPhotoLibrary.shared().performChanges {
PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
}
}
private func sizeForAspectRatio(_ ratio: String) -> CGSize {
switch ratio {
case "16:9": return CGSize(width: 1920, height: 1080)
case "1:1":  return CGSize(width: 1080, height: 1080)
case "4:5":  return CGSize(width: 1080, height: 1350)
default:     return CGSize(width: 1080, height: 1920)
}
}
}
struct ContentView: View {
@State private var selectedItems: [PhotosPickerItem] = []
@State private var refPhotoItem: PhotosPickerItem?
@State private var referenceImage: UIImage?
@State private var clipURLs: [URL] = []
@State private var clipDurations: [Double] = []
@State private var clipTranscripts: [String] = []
@State private var versions: [TimelineProject] = []
@State private var activeVersionIdx: Int = -1
@State private var previewURL: URL?
@State private var selectedMode: AIMode = .balanced
@State private var promptText: String = ""
@AppStorage("gemini_api_key") private var apiKey: String = ""
@State private var showKeySheet = false
@State private var isBusy = false
@State private var statusBanner = "Import clips, show a reference photo or explain your edit."
private let engine = NarrativeEngine()
var currentProject: TimelineProject? {
guard activeVersionIdx >= 0 && activeVersionIdx < versions.count else { return nil }
return versions[activeVersionIdx]
}
var body: some View {
NavigationStack {
VStack(spacing: 10) {
HStack(spacing: 8) {
PhotosPicker(selection: $selectedItems, maxSelectionCount: 12, matching: .videos) {
Label("Import", systemImage: "plus.rectangle.on.folder").font(.caption.bold())
}
.buttonStyle(.bordered)
Picker("Mode", selection: $selectedMode) {
ForEach(AIMode.allCases, id: .self) { Text($0.rawValue).tag($0) }
}
.pickerStyle(.segmented)
Button { showKeySheet = true } label: {
Image(systemName: apiKey.isEmpty ? "key.fill" : "checkmark.shield.fill")
.foregroundColor(apiKey.isEmpty ? .orange : .green)
}
.buttonStyle(.bordered)
if let url = previewURL {
Button {
Task {
try? await engine.saveToCameraRoll(url)
statusBanner = "Exported video to Camera Roll!"
}
} label: { Image(systemName: "square.and.arrow.up") }
.buttonStyle(.borderedProminent).tint(.purple)
}
}
ZStack {
RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06))
if let url = previewURL ?? clipURLs.first {
VideoPlayer(player: AVPlayer(url: url)).cornerRadius(16)
} else {
VStack(spacing: 8) {
Image(systemName: "sparkles.tv").font(.system(size: 38)).foregroundColor(.purple)
Text("Narrative AI Studio").font(.headline)
Text("Tap Import to load clips from Camera Roll").font(.caption).foregroundColor(.secondary)
}
}
}
.frame(height: 245)
if !versions.isEmpty {
ScrollView(.horizontal, showsIndicators: false) {
HStack(spacing: 8) {
ForEach(versions.indices, id: .self) { idx in
Button("v(idx + 1)") {
activeVersionIdx = idx
Task { await renderActive() }
}
.font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 5)
.background(activeVersionIdx == idx ? Color.purple : Color.white.opacity(0.1))
.foregroundColor(.white).clipShape(Capsule())
}
}
}
}
if let proj = currentProject {
VStack(alignment: .leading, spacing: 6) {
HStack {
Text("MULTITRACK TIMELINE • (proj.aspect_ratio)").font(.caption2.bold()).foregroundColor(.secondary)
Spacer()
if proj.auto_captions {
Label("Captions ON", systemImage: "captions.bubble.fill").font(.caption2.bold()).foregroundColor(.purple)
}
}
ScrollView(.horizontal, showsIndicators: false) {
HStack(spacing: 6) {
ForEach(proj.clips) { clip in
VStack(alignment: .leading, spacing: 2) {
Text(clip.label ?? "Clip (clip.clip_index + 1)").font(.caption2.bold())
Text("(String(format: "%.1f", clip.start_seconds))s–(String(format: "%.1f", clip.end_seconds))s • (String(format: "%.1f", clip.speed))x")
.font(.caption2).foregroundColor(.white.opacity(0.8))
}
.padding(8).background(Color.purple.opacity(0.35))
.overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple, lineWidth: 1)).cornerRadius(8)
}
}
}
}
}
Text(statusBanner).font(.caption).foregroundColor(.white.opacity(0.9)).padding(10)
.frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.07)).cornerRadius(10)
if let refImg = referenceImage {
HStack {
Image(uiImage: refImg).resizable().scaledToFill().frame(width: 36, height: 36).cornerRadius(6)
Text("Reference look attached").font(.caption2).foregroundColor(.purple)
Spacer()
Button("Remove") { referenceImage = nil; refPhotoItem = nil }.font(.caption2)
}
.padding(6).background(Color.purple.opacity(0.15)).cornerRadius(8)
}
HStack(spacing: 8) {
PhotosPicker(selection: $refPhotoItem, matching: .images) {
Image(systemName: "photo.badge.plus")
.font(.title3)
.foregroundColor(.purple)
}
TextField("Show a style or explain your edit...", text: $promptText)
.textFieldStyle(.roundedBorder)
Button { Task { await runNarrativePrompt() } } label: {
if isBusy { ProgressView() }
else { Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundColor(.purple) }
}
.disabled(clipURLs.isEmpty || (promptText.isEmpty && referenceImage == nil) || isBusy)
}
}
.padding()
.navigationTitle("Narrative")
.navigationBarTitleDisplayMode(.inline)
.onChange(of: selectedItems) { _, items in Task { await importVideos(items) } }
.onChange(of: refPhotoItem) { _, item in
Task {
if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
referenceImage = img
}
}
}
.sheet(isPresented: $showKeySheet) {
NavigationStack {
Form {
Section("Free Google Gemini API Key") {
SecureField("Paste AIza... key here", text: $apiKey)
Text("Get a free key at google.com. Saved automatically on device.")
.font(.caption).foregroundColor(.secondary)
}
}
.navigationTitle("AI Settings")
.toolbar { Button("Done") { showKeySheet = false } }
}
.presentationDetents([.medium])
}
}
}
func importVideos(_ items: [PhotosPickerItem]) async {
clipURLs.removeAll(); clipDurations.removeAll(); clipTranscripts.removeAll()
statusBanner = "Indexing clips & speech for AI search..."
for (i, item) in items.enumerated() {
if let data = try? await item.loadTransferable(type: Data.self) {
let url = FileManager.default.temporaryDirectory.appendingPathComponent("src_(i).mov")
try? data.write(to: url)
let dur = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 5.0
let transcript = await engine.transcribeClip(url: url)
clipURLs.append(url); clipDurations.append(dur); clipTranscripts.append(transcript)
}
}
statusBanner = "Indexed (clipURLs.count) clip(s). Show an image or explain your cut!"
}
func runNarrativePrompt() async {
guard !apiKey.isEmpty else { showKeySheet = true; return }
isBusy = true
let prompt = promptText.isEmpty ? "Match the style, framing, and vibe of the attached reference image" : promptText
promptText = ""
statusBanner = "Narrative ((selectedMode.rawValue)) is directing your cut..."
do {
var nextProj = try await engine.updateTimeline(
prompt: prompt,
mode: selectedMode,
clipDurations: clipDurations,
transcripts: clipTranscripts,
referenceImage: referenceImage,
currentTimeline: currentProject,
apiKey: apiKey
)
nextProj.versionLabel = "v(versions.count + 1)"
versions.append(nextProj)
activeVersionIdx = versions.count - 1
statusBanner = nextProj.assistant_reply ?? "Timeline updated."
await renderActive()
} catch {
statusBanner = "Error: (error.localizedDescription)"
}
isBusy = false
}
func renderActive() async {
guard let proj = currentProject else { return }
if let url = try? await engine.renderProject(sourceURLs: clipURLs, project: proj) { previewURL = url }
}
}
