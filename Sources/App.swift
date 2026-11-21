import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
import Speech
import Photos
import UIKit
import UniformTypeIdentifiers

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

struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
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
    func transcribe(url: URL) async -> [TextOverlay] {
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
                    if words.count >= 3 {
                        list.append(TextOverlay(text: words.joined(separator: " "), start_seconds: start, end_seconds: s.timestamp + s.duration, position: "bottom"))
                        words.removeAll()
                    }
                }
                if !words.isEmpty, let last = res.bestTranscription.segments.last {
                    list.append(TextOverlay(text: words.joined(separator: " "), start_seconds: start, end_seconds: last.timestamp + last.duration, position: "bottom"))
                }
                c.resume(returning: list)
            }
        }
    }
    
    func edit(prompt: String, mode: AIMode, aspect: String, durs: [Double], transcripts: [String], ref: UIImage?, cur: TimelineProject?, key: String) async throws -> TimelineProject {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = "https://googleapis.com" + mode.model + ":generateContent?key=" + k
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let curStr = (try? String(data: JSONEncoder().encode(cur), encoding: .utf8)) ?? "None"
        let info = durs.enumerated().map { idx, d in
            let sp = idx < transcripts.count && !transcripts[idx].isEmpty ? " | Spoken words: " + transcripts[idx] : ""
            return "Clip " + String(idx) + " (" + String(Int(d)) + "s)" + sp
        }.joined(separator: "\n")
        let sys = "You are Narrative, an AI-first video editor. Cut the user's footage based on their prompt, spoken dialogue, and any reference image. Only create overlays from real spoken words or titles requested by the user. Target aspect ratio: " + aspect + ". Output ONLY valid JSON: {\"aspect_ratio\":\"" + aspect + "\",\"clips\":[{\"clip_index\":0,\"start_seconds\":0.0,\"end_seconds\":4.0,\"speed\":1.0,\"label\":\"Clip 1\"}],\"overlays\":[],\"auto_captions\":true,\"assistant_reply\":\"Summary of edits\"}\nFootage:\n" + info + "\nCurrent Timeline:\n" + curStr + "\nUser Request: " + prompt
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
    
    func render(urls: [URL], proj: TimelineProject, fallbackAspect: String) async throws -> URL {
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
        let ratio = proj.aspect_ratio.isEmpty ? fallbackAspect : proj.aspect_ratio
        let size: CGSize = ratio == "16:9" ? CGSize(width: 1920, height: 1080) : ratio == "1:1" ? CGSize(width: 1080, height: 1080) : CGSize(width: 1080, height: 1920)
        let vComp = AVMutableVideoComposition(); vComp.renderSize = size; vComp.frameDuration = CMTime(value: 1, timescale: 30)
        let inst = AVMutableVideoCompositionInstruction(); inst.timeRange = CMTimeRange(start: .zero, duration: cursor)
        inst.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)]; vComp.instructions = [inst]
        let parent = CALayer(), vLayer = CALayer()
        parent.frame = CGRect(origin: .zero, size: size); vLayer.frame = CGRect(origin: .zero, size: size); parent.addSublayer(vLayer)
        for o in proj.overlays {
            let t = CATextLayer(); t.string = o.text; t.font = UIFont.systemFont(ofSize: 54, weight: .heavy)
            t.fontSize = 54; t.foregroundColor = UIColor.white.cgColor
            t.shadowColor = UIColor.black.cgColor; t.shadowOpacity = 0.95; t.shadowRadius = 6; t.shadowOffset = CGSize(width: 0, height: 3)
            t.alignmentMode = .center; t.opacity = 0
            t.frame = CGRect(x: 40, y: o.position == "top" ? size.height * 0.8 : o.position == "center" ? size.height * 0.45 : size.height * 0.12, width: size.width - 80, height: 84)
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
    @State private var showVideoPicker = false
    @State private var showRefPicker = false
    @State private var items: [PhotosPickerItem] = []
    @State private var refItem: PhotosPickerItem?
    @State private var refImg: UIImage?
    @State private var urls: [URL] = []
    @State private var durs: [Double] = []
    @State private var transcripts: [String] = []
    @State private var versions: [TimelineProject] = []
    @State private var idx = -1
    @State private var preview: URL?
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var aspect = "16:9"
    @State private var mode: AIMode = .balanced
    @State private var prompt = ""
    @State private var busy = false
    @State private var status = "Bring your footage, say what you want made"
    @AppStorage("gemini_api_key") private var apiKey = ""
    @State private var showKey = false
    let engine = NarrativeEngine()
    
    var canvasHeight: CGFloat { aspect == "16:9" ? 215 : aspect == "1:1" ? 275 : 330 }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button { showKey = true } label: {
                        Image(systemName: apiKey.isEmpty ? "key.fill" : "xmark")
                            .font(.subheadline.bold())
                            .foregroundColor(apiKey.isEmpty ? .orange : .white)
                    }
                    Menu {
                        ForEach(AIMode.allCases, id: \.self) { m in Button(m.rawValue) { mode = m } }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play").font(.subheadline.bold())
                            Text("Narrative").font(.headline.bold())
                        }.foregroundColor(.white)
                    }
                    Spacer()
                    Button {
                        aspect = aspect == "16:9" ? "9:16" : aspect == "9:16" ? "1:1" : "16:9"
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: aspect == "16:9" ? "rectangle" : aspect == "9:16" ? "rectangle.portrait" : "square")
                                .font(.caption2)
                            Text(aspect).font(.caption.bold())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.12)).cornerRadius(8)
                    }
                    Button {
                        if let u = preview ?? urls.first {
                            Task {
                                try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: u) }
                                status = "Exported to Camera Roll!"
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Export").font(.subheadline.bold())
                            Image(systemName: "square.and.arrow.up").font(.caption.bold())
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.white).cornerRadius(8)
                    }
                }.padding(.horizontal)
                
                Spacer(minLength: 0)
                
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07))
                    if preview != nil || !urls.isEmpty {
                        VideoPlayer(player: player).cornerRadius(12)
                    } else {
                        Button { showVideoPicker = true } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill").font(.system(size: 38)).foregroundColor(Color(red: 0.45, green: 0.35, blue: 0.95))
                                Text("Bring your footage").font(.subheadline.bold()).foregroundColor(.white)
                            }
                        }
                    }
                }.frame(height: canvasHeight).padding(.horizontal)
                
                Spacer(minLength: 0)
                
                HStack {
                    Button {
                        if isPlaying { player.pause() } else { player.play() }
                        isPlaying.toggle()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.body).foregroundColor(.white)
                    }
                    Spacer()
                    Text(idx >= 0 ? "Version " + String(idx + 1) : status).font(.caption2).foregroundColor(.gray).lineLimit(1)
                    Spacer()
                    HStack(spacing: 14) {
                        Button { if idx > 0 { idx -= 1; Task { await loadPreview(versions[idx]) } } } label: { Image(systemName: "arrow.uturn.backward").font(.caption).foregroundColor(idx > 0 ? .white : .gray) }
                        Button { if idx + 1 < versions.count { idx += 1; Task { await loadPreview(versions[idx]) } } } label: { Image(systemName: "arrow.uturn.forward").font(.caption).foregroundColor(idx + 1 < versions.count ? .white : .gray) }
                    }
                }.padding(.horizontal, 18)
                
                ZStack {
                    VStack(spacing: 8) {
                        HStack {
                            ForEach(1...6, id: \.self) { sec in
                                Rectangle().fill(Color.gray.opacity(0.5)).frame(width: 1, height: 8)
                                Text(String(sec) + "s").font(.caption2.monospacedDigit()).foregroundColor(.gray)
                                Spacer()
                            }
                            Button { showVideoPicker = true } label: {
                                Image(systemName: "plus.circle.fill").font(.subheadline).foregroundColor(.white)
                            }
                        }.padding(.horizontal, 12)
                        
                        if idx >= 0 && idx < versions.count && !versions[idx].overlays.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(versions[idx].overlays) { o in
                                        Text(o.text).font(.caption.bold()).foregroundColor(.white)
                                            .padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(Color(red: 0.43, green: 0.34, blue: 0.96)).cornerRadius(8)
                                    }
                                }.padding(.horizontal, 12)
                            }
                        }
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                if idx >= 0 && idx < versions.count {
                                    ForEach(versions[idx].clips) { c in
                                        HStack(spacing: 6) {
                                            Text(c.label ?? "Clip " + String(c.clip_index + 1)).font(.caption2.bold()).foregroundColor(.white)
                                            Rectangle().fill(Color.pink).frame(width: 3, height: 24)
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Color(red: 0.45, green: 0.08, blue: 0.16)).cornerRadius(6)
                                    }
                                } else if !urls.isEmpty {
                                    ForEach(urls.indices, id: \.self) { i in
                                        Text("Clip " + String(i + 1) + " (" + String(Int(durs[i])) + "s)")
                                            .font(.caption2.bold()).foregroundColor(.white)
                                            .padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(Color(red: 0.45, green: 0.08, blue: 0.16)).cornerRadius(6)
                                    }
                                } else {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)).frame(height: 32)
                                }
                            }.padding(.horizontal, 12)
                        }
                    }
                    Rectangle().fill(Color.white).frame(width: 2, height: 95)
                }
                
                HStack(spacing: 8) {
                    Button { showRefPicker = true } label: {
                        Image(systemName: refImg == nil ? "photo.badge.plus" : "checkmark.circle.fill")
                            .font(.title3).foregroundColor(Color(red: 0.43, green: 0.34, blue: 0.96))
                    }
                    TextField("Say what you want made...", text: $prompt)
                        .font(.subheadline).padding(9).background(Color.white.opacity(0.1)).cornerRadius(18)
                    Button { Task { await run() } } label: {
                        if busy { ProgressView().tint(.white) }
                        else { Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundColor(Color(red: 0.43, green: 0.34, blue: 0.96)) }
                    }.disabled(urls.isEmpty || (prompt.isEmpty && refImg == nil) || busy)
                }.padding(.horizontal).padding(.bottom, 6)
            }
        }
photosPicker(isPresented: $showVideoPicker, selection: $items, maxSelectionCount: 8, matching: .videos, preferredItemEncoding: .compatible)
.photosPicker(isPresented: $showRefPicker, selection: $refItem, matching: .images)
.onChange(of: items) { _, list in Task { await load(list) } }
.onChange(of: refItem) { _, it in Task { if let d = try? await it?.loadTransferable(type: Data.self) { refImg = UIImage(data: d) } } }
.sheet(isPresented: $showKey) {
NavigationStack { Form { SecureField("Free Gemini API Key (AIza...)", text: $apiKey) }.navigationTitle("AI Settings").toolbar { Button("Done") { showKey = false } } }.presentationDetents([.medium])
}
}
@MainActor func load(_ list: [PhotosPickerItem]) async {
guard !list.isEmpty else { return }
urls.removeAll(); durs.removeAll(); transcripts.removeAll(); status = "Importing clips..."
for it in list {
if let movie = try? await it.loadTransferable(type: MovieFile.self) {
let u = movie.url
let dur = (try? await AVURLAsset(url: u).load(.duration).seconds) ?? 5.0
let words = await engine.transcribe(url: u)
let spoken = words.map { $0.text }.joined(separator: " ")
urls.append(u); durs.append(dur); transcripts.append(spoken)
}
}
items.removeAll()
if let first = urls.first { player = AVPlayer(url: first) }
status = "Imported " + String(urls.count) + " clip(s)"
}
@MainActor func loadPreview(_ proj: TimelineProject) async {
if let out = try? await engine.render(urls: urls, proj: proj, fallbackAspect: aspect) {
preview = out; player = AVPlayer(url: out); player.play(); isPlaying = true
}
}
@MainActor func run() async {
guard !apiKey.isEmpty else { showKey = true; return }
busy = true; let p = prompt.isEmpty ? "Match reference image style" : prompt; prompt = ""; status = "Cutting (" + mode.rawValue + ")..."
do {
var proj = try await engine.edit(prompt: p, mode: mode, aspect: aspect, durs: durs, transcripts: transcripts, ref: refImg, cur: idx >= 0 ? versions[idx] : nil, key: apiKey)
if proj.auto_captions && proj.overlays.isEmpty, let first = urls.first {
proj.overlays = await engine.transcribe(url: first)
}
versions.append(proj); idx = versions.count - 1; status = proj.assistant_reply ?? "Done!"
await loadPreview(proj)
} catch { status = "Error: " + error.localizedDescription }
busy = false
}
}
