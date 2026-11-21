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
        WindowGroup { ContentView().preferredColorScheme(.dark) }
    }
}

enum AIMode: String, CaseIterable {
    case fast = "Fast", balanced = "Balanced", max = "Max"
    var model: String { self == .max ? "gemini-2.5-pro" : "gemini-2.5-flash" }
}

struct TimelineProject: Codable, Identifiable {
    var id = UUID()
    var aspect_ratio: String
    var clips: [TimelineClip]
    var overlays: [TextOverlay]
    var auto_captions: Bool
    var assistant_reply: String?
    enum CodingKeys: String, CodingKey { case aspect_ratio, clips, overlays, auto_captions, assistant_reply }
}

struct TimelineClip: Codable, Identifiable {
    var id = UUID()
    var clip_index: Int
    var start_seconds: Double
    var end_seconds: Double
    var speed: Double
    var label: String?
    enum CodingKeys: String, CodingKey { case clip_index, start_seconds, end_seconds, speed, label }
}

struct TextOverlay: Codable, Identifiable {
    var id = UUID()
    var text: String
    var start_seconds: Double
    var end_seconds: Double
    var position: String
    enum CodingKeys: String, CodingKey { case text, start_seconds, end_seconds, position }
}

class NarrativeEngine {
    func transcribe(url: URL) async -> String {
        let auth = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard auth == .authorized, let rec = SFSpeechRecognizer(), rec.isAvailable else { return "" }
        let req = SFSpeechURLRecognitionRequest(url: url); req.shouldReportPartialResults = false
        return await withCheckedContinuation { c in
            rec.recognitionTask(with: req) { res, err in
                guard let res = res, res.isFinal else { if err != nil { c.resume(returning: "") }; return }
                let items = res.bestTranscription.segments.map { "[" + String(Int($0.timestamp)) + "s:" + $0.substring + "]" }
                c.resume(returning: items.joined(separator: " "))
            }
        }
    }
    
    func captions(url: URL) async -> [TextOverlay] {
        let auth = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard auth == .authorized, let rec = SFSpeechRecognizer(), rec.isAvailable else { return [] }
        let req = SFSpeechURLRecognitionRequest(url: url); req.shouldReportPartialResults = false
        return await withCheckedContinuation { c in
            rec.recognitionTask(with: req) { res, err in
                guard let res = res, res.isFinal else { if err != nil { c.resume(returning: []) }; return }
                var list: [TextOverlay] = [], words: [String] = [], start = 0.0
                for s in res.bestTranscription.segments {
                    if words.isEmpty { start = s.timestamp }
                    words.append(s.substring)
                    if words.count >= 4 {
                        list.append(TextOverlay(text: words.joined(separator: " "), start_seconds: start, end_seconds: s.timestamp + s.duration, position: "bottom"))
                        words.removeAll()
                    }
                }
                c.resume(returning: list)
            }
        }
    }
    
    func edit(prompt: String, mode: AIMode, durs: [Double], speech: [String], ref: UIImage?, cur: TimelineProject?, key: String) async throws -> TimelineProject {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = "https://googleapis.com" + mode.model + ":generateContent?key=" + k
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"; req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let curStr = (try? String(data: JSONEncoder().encode(cur), encoding: .utf8)) ?? "None"
        let info = durs.enumerated().map { "Clip " + String($0.offset) + " (" + String(Int($0.element)) + "s) Speech: " + speech[$0.offset] }.joined(separator: "\n")
        let sys = "You are Narrative AI video editor. Match reference images, search spoken words, cut clips, and add titles/captions. Output ONLY valid JSON: {\"aspect_ratio\":\"9:16\",\"clips\":[{\"clip_index\":0,\"start_seconds\":0.0,\"end_seconds\":5.0,\"speed\":1.0,\"label\":\"Hook\"}],\"overlays\":[{\"text\":\"Title\",\"start_seconds\":0.0,\"end_seconds\":2.0,\"position\":\"center\"}],\"auto_captions\":true,\"assistant_reply\":\"Done\"}\nClips:\n" + info + "\nCurrent:\n" + curStr + "\nRequest:" + prompt
        var parts: [[String: Any]] = [["text": sys]]
        if let d = ref?.jpegData(compressionQuality: 0.6) {
            parts.append(["inline_data": ["mime_type": "image/jpeg", "data": d.base64EncodedString()]])
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["contents": [["parts": parts]], "generationConfig": ["responseMimeType": "application/json"]])
        let (data, _) = try await URLSession.shared.data(for: req)
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let err = (raw?["error"] as? [String: Any])?["message"] as? String { throw NSError(domain: "AI", code: 400, userInfo: [NSLocalizedDescriptionKey: err]) }
        let txt = (((raw?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String ?? "{}"
        return try JSONDecoder().decode(TimelineProject.self, from: Data(txt.utf8))
    }
    
    func render(urls: [URL], proj: TimelineProject) async throws -> URL {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw NSError(domain: "N", code: 1) }
        var cursor = CMTime.zero
        for c in proj.clips where c.clip_index < urls.count {
            let asset = AVURLAsset(url: urls[c.clip_index])
            let dur = try await asset.load(.duration).seconds
            let range = CMTimeRange(start: CMTime(seconds: max(0, c.start_seconds), preferredTimescale: 600), end: CMTime(seconds: min(c.end_seconds, dur), preferredTimescale: 600))
            if range.duration.seconds <= 0 { continue }
            if let v = try await asset.loadTracks(withMediaType: .video).first { try vTrack.insertTimeRange(range, of: v, at: cursor) }
            if let a = try await asset.loadTracks(withMediaType: .audio).first { try aTrack.insertTimeRange(range, of: a, at: cursor) }
            let scaled = CMTimeMultiplyByFloat64(range.duration, multiplier: 1.0 / max(0.25, min(c.speed, 4.0)))
            vTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: scaled)
            aTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: scaled)
            cursor = CMTimeAdd(cursor, scaled)
        }
        var overlays = proj.overlays
        if proj.auto_captions, let first = urls.first { overlays += await captions(url: first) }
        let size: CGSize = proj.aspect_ratio == "16:9" ? CGSize(width: 1920, height: 1080) : proj.aspect_ratio == "1:1" ? CGSize(width: 1080, height: 1080) : CGSize(width: 1080, height: 1920)
        let vComp = AVMutableVideoComposition(); vComp.renderSize = size; vComp.frameDuration = CMTime(value: 1, timescale: 30)
        let inst = AVMutableVideoCompositionInstruction(); inst.timeRange = CMTimeRange(start: .zero, duration: cursor)
        inst.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)]; vComp.instructions = [inst]
        let parent = CALayer(), vLayer = CALayer()
        parent.frame = CGRect(origin: .zero, size: size); vLayer.frame = CGRect(origin: .zero, size: size); parent.addSublayer(vLayer)
        for o in overlays {
            let t = CATextLayer(); t.string = o.text; t.fontSize = 46; t.foregroundColor = UIColor.white.cgColor
            t.backgroundColor = UIColor.black.withAlphaComponent(0.75).cgColor; t.alignmentMode = .center; t.cornerRadius = 12; t.opacity = 0
            t.frame = CGRect(x: 50, y: o.position == "top" ? size.height * 0.8 : o.position == "bottom" ? size.height * 0.14 : size.height * 0.48, width: size.width - 100, height: 74)
            let show = CABasicAnimation(keyPath: "opacity"); show.fromValue = 0; show.toValue = 1; show.beginTime = AVCoreAnimationBeginTimeAtZero + o.start_seconds; show.duration = 0.05; show.fillMode = .forwards; show.isRemovedOnCompletion = false
            let hide = CABasicAnimation(keyPath: "opacity"); hide.fromValue = 1; hide.toValue = 0; hide.beginTime = AVCoreAnimationBeginTimeAtZero + o.end_seconds; hide.duration = 0.05; hide.fillMode = .forwards; hide.isRemovedOnCompletion = false
            t.add(show, forKey: "s"); t.add(hide, forKey: "h"); parent.addSublayer(t)
        }
        vComp.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: vLayer, in: parent)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out_" + UUID().uuidString + ".mp4")
        guard let exp = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw NSError(domain: "N", code: 2) }
        exp.outputURL = out; exp.outputFileType = .mp4; exp.videoComposition = vComp; await exp.export()
        return out
    }
}
@MainActor
struct ContentView: View {
    @State private var items: [PhotosPickerItem] = []
    @State private var refItem: PhotosPickerItem?
    @State private var refImg: UIImage?
    @State private var urls: [URL] = []
    @State private var durs: [Double] = []
    @State private var speeches: [String] = []
    @State private var versions: [TimelineProject] = []
    @State private var idx = -1
    @State private var preview: URL?
    @State private var mode: AIMode = .balanced
    @State private var prompt = ""
    @State private var busy = false
    @State private var status = "Import clips, show a photo or explain your edit."
    @AppStorage("gemini_api_key") private var apiKey = ""
    @State private var showKey = false
    let engine = NarrativeEngine()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack {
                    PhotosPicker(selection: $items, maxSelectionCount: 12, matching: .videos) { Label("Import", systemImage: "plus.rectangle.on.folder").font(.caption.bold()) }.buttonStyle(.bordered)
                    Picker("Mode", selection: $mode) { ForEach(AIMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    Button { showKey = true } label: { Image(systemName: apiKey.isEmpty ? "key.fill" : "checkmark.shield.fill").foregroundColor(apiKey.isEmpty ? .orange : .green) }.buttonStyle(.bordered)
                    if let u = preview {
                        Button {
                            Task { try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: u) }; status = "Saved to Photos!" }
                        } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderedProminent).tint(.purple)
                    }
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06))
                    if let u = preview ?? urls.first { VideoPlayer(player: AVPlayer(url: u)).cornerRadius(16) }
                    else { VStack { Image(systemName: "sparkles.tv").font(.largeTitle).foregroundColor(.purple); Text("Narrative AI Studio").font(.headline) } }
                }.frame(height: 245)
                if !versions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(versions.indices, id: \.self) { i in Button("v" + String(i + 1)) { idx = i; Task { preview = try? await engine.render(urls: urls, proj: versions[i]) } }.font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 5).background(idx == i ? Color.purple : Color.white.opacity(0.1)).foregroundColor(.white).clipShape(Capsule()) } }
                    }
                }
                if idx >= 0 && idx < versions.count {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(versions[idx].clips) { c in
                                VStack(alignment: .leading) {
                                    Text(c.label ?? ("Clip " + String(c.clip_index + 1))).font(.caption2.bold())
                                    Text(verbatim: [String(Int(c.start_seconds)), "s-", String(Int(c.end_seconds)), "s (", String(c.speed), "x)"].joined()).font(.caption2)
                                }.padding(8).background(Color.purple.opacity(0.35)).cornerRadius(8)
                            }
                        }
                    }
                }
                Text(status).font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.07)).cornerRadius(10)
                if let img = refImg {
                    HStack { Image(uiImage: img).resizable().scaledToFill().frame(width: 34, height: 34).cornerRadius(6); Text("Reference image attached").font(.caption2).foregroundColor(.purple); Spacer(); Button("X") { refImg = nil; refItem = nil }.font(.caption2) }.padding(6).background(Color.purple.opacity(0.15)).cornerRadius(8)
                }
                HStack {
                    PhotosPicker(selection: $refItem, matching: .images) { Image(systemName: "photo.badge.plus").font(.title3).foregroundColor(.purple) }
                    TextField("Show style or explain edit...", text: $prompt).textFieldStyle(.roundedBorder)
                    Button { Task { await run() } } label: { busy ? AnyView(ProgressView()) : AnyView(Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundColor(.purple)) }.disabled(urls.isEmpty || (prompt.isEmpty && refImg == nil) || busy)
                }
            }.padding().navigationTitle("Narrative").navigationBarTitleDisplayMode(.inline)
            .onChange(of: items) { _, list in Task { await load(list) } }
            .onChange(of: refItem) { _, it in Task { if let d = try? await it?.loadTransferable(type: Data.self) { refImg = UIImage(data: d) } } }
            .sheet(isPresented: $showKey) {
                NavigationStack { Form { SecureField("Free Gemini API Key (AIza...)", text: $apiKey) }.navigationTitle("AI Key").toolbar { Button("Done") { showKey = false } } }.presentationDetents([.medium])
            }
        }
    }
    @MainActor func load(_ list: [PhotosPickerItem]) async {
        urls.removeAll(); durs.removeAll(); speeches.removeAll(); status = "Indexing clips & speech..."
        for (i, it) in list.enumerated() {
            if let d = try? await it.loadTransferable(type: Data.self) {
                let u = FileManager.default.temporaryDirectory.appendingPathComponent("s_" + String(i) + ".mov"); try? d.write(to: u)
                let dur = (try? await AVURLAsset(url: u).load(.duration).seconds) ?? 5.0
                urls.append(u); durs.append(dur); speeches.append(await engine.transcribe(url: u))
            }
        }
        status = "Loaded " + String(urls.count) + " clip(s). Show an image or explain your edit!"
    }
    @MainActor func run() async {
        guard !apiKey.isEmpty else { showKey = true; return }
        busy = true; let p = prompt.isEmpty ? "Match reference image style" : prompt; prompt = ""; status = "Editing (" + mode.rawValue + ")..."
        do {
            let proj = try await engine.edit(prompt: p, mode: mode, durs: durs, speech: speeches, ref: refImg, cur: idx >= 0 ? versions[idx] : nil, key: apiKey)
            versions.append(proj); idx = versions.count - 1; status = proj.assistant_reply ?? "Updated!"; preview = try? await engine.render(urls: urls, proj: proj)
        } catch { status = "Error: " + error.localizedDescription }
        busy = false
    }
}


