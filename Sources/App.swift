import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
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
    func edit(prompt: String, mode: AIMode, durs: [Double], ref: UIImage?, cur: TimelineProject?, key: String) async throws -> TimelineProject {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = "https://googleapis.com" + mode.model + ":generateContent?key=" + k
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let curStr = (try? String(data: JSONEncoder().encode(cur), encoding: .utf8)) ?? "None"
        let info = durs.enumerated().map { "Clip " + String($0.offset) + " (" + String(Int($0.element)) + "s)" }.joined(separator: ", ")
        let sys = "You are Narrative AI video editor. Match reference images, create punchy rhythm cuts, and generate bold short caption overlays. Output ONLY valid JSON: {\"aspect_ratio\":\"1:1\",\"clips\":[{\"clip_index\":0,\"start_seconds\":0.0,\"end_seconds\":3.0,\"speed\":1.0,\"label\":\"Hook\"}],\"overlays\":[{\"text\":\"\\\"In his prime\\\"\",\"start_seconds\":0.0,\"end_seconds\":3.0,\"position\":\"bottom\"}],\"auto_captions\":true,\"assistant_reply\":\"Cut synced to beat with bold captions\"}\nClips: " + info + "\nCurrent: " + curStr + "\nRequest: " + prompt
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
        let size: CGSize = proj.aspect_ratio == "16:9" ? CGSize(width: 1920, height: 1080) : proj.aspect_ratio == "9:16" ? CGSize(width: 1080, height: 1920) : CGSize(width: 1080, height: 1080)
        let vComp = AVMutableVideoComposition(); vComp.renderSize = size; vComp.frameDuration = CMTime(value: 1, timescale: 30)
        let inst = AVMutableVideoCompositionInstruction(); inst.timeRange = CMTimeRange(start: .zero, duration: cursor)
        inst.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)]; vComp.instructions = [inst]
        let parent = CALayer(), vLayer = CALayer()
        parent.frame = CGRect(origin: .zero, size: size); vLayer.frame = CGRect(origin: .zero, size: size); parent.addSublayer(vLayer)
        for o in proj.overlays {
            let t = CATextLayer(); t.string = o.text; t.font = UIFont.systemFont(ofSize: 58, weight: .heavy)
            t.fontSize = 58; t.foregroundColor = UIColor.white.cgColor
            t.shadowColor = UIColor.black.cgColor; t.shadowOpacity = 0.95; t.shadowRadius = 6; t.shadowOffset = CGSize(width: 0, height: 3)
            t.alignmentMode = .center; t.opacity = 0
            t.frame = CGRect(x: 40, y: o.position == "top" ? size.height * 0.8 : o.position == "center" ? size.height * 0.45 : size.height * 0.12, width: size.width - 80, height: 90)
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
    @State private var versions: [TimelineProject] = []
    @State private var idx = -1
    @State private var preview: URL?
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var mode: AIMode = .balanced
    @State private var prompt = ""
    @State private var busy = false
    @State private var status = "Tap + Import or ask Narrative AI to cut & caption"
    @AppStorage("gemini_api_key") private var apiKey = ""
    @State private var showKey = false
    let engine = NarrativeEngine()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                HStack {
                    Button { showKey = true } label: {
                        Image(systemName: apiKey.isEmpty ? "key.fill" : "xmark").font(.headline).foregroundColor(apiKey.isEmpty ? .orange : .white)
                    }
                    Spacer()
                    Menu {
                        ForEach(AIMode.allCases, id: \.self) { m in Button(m.rawValue) { mode = m } }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.caption2)
                            Text("Narrative").font(.headline.bold())
                            Image(systemName: "chevron.down").font(.caption)
                        }.foregroundColor(.white)
                    }
                    Spacer()
                    Text("HD").font(.caption.bold()).foregroundColor(.gray).padding(.horizontal, 6)
                    Button {
                        if let u = preview ?? urls.first {
                            Task {
                                try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: u) }
                                status = "Exported HD video to Camera Roll!"
                            }
                        }
                    } label: {
                        Text("Next >").font(.subheadline.bold()).foregroundColor(.black)
                            .padding(.horizontal, 14).padding(.vertical, 6).background(Color.white).clipShape(Capsule())
                    }
                }.padding(.horizontal)
                
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07))
                    if preview != nil || !urls.isEmpty {
                        VideoPlayer(player: player).cornerRadius(14)
                    } else {
                        Button { showVideoPicker = true } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill").font(.system(size: 40)).foregroundColor(Color(red: 0.45, green: 0.35, blue: 0.95))
                                Text("Tap to Import Clips").font(.subheadline.bold()).foregroundColor(.white)
                            }
                        }
                    }
                    if idx >= 0 && idx < versions.count, let firstCap = versions[idx].overlays.first {
                        Text(firstCap.text)
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundColor(.white)
                            .shadow(color: .black, radius: 4, x: 0, y: 2)
                            .padding(.bottom, 18)
                    }
                }.frame(height: 290).padding(.horizontal)
                
                HStack {
                    Button {
                        if isPlaying { player.pause() } else { player.play() }
                        isPlaying.toggle()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title3).foregroundColor(.white)
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text("00:05").font(.caption.monospacedDigit().bold()).foregroundColor(.white)
                        Text(idx >= 0 ? "v" + String(idx + 1) : "01:00").font(.caption2.monospacedDigit()).foregroundColor(.gray)
                    }
                    Spacer()
                    HStack(spacing: 14) {
                        Button { if idx > 0 { idx -= 1; Task { await loadPreview(versions[idx]) } } } label: { Image(systemName: "arrow.uturn.backward").foregroundColor(idx > 0 ? .white : .gray) }
                        Button { if idx + 1 < versions.count { idx += 1; Task { await loadPreview(versions[idx]) } } } label: { Image(systemName: "arrow.uturn.forward").foregroundColor(idx + 1 < versions.count ? .white : .gray) }
                    }
                }.padding(.horizontal, 20)
                
                ZStack {
                    VStack(spacing: 8) {
                        HStack {
                            ForEach(1...7, id: \.self) { sec in
                                Text(String(sec) + "s").font(.caption2.monospacedDigit()).foregroundColor(.gray)
                                Spacer()
                            }
                            Button { showVideoPicker = true } label: {
                                Image(systemName: "plus.circle.fill").font(.title3).foregroundColor(.white)
                            }
                        }.padding(.horizontal, 12)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                if idx >= 0 && idx < versions.count {
                                    ForEach(versions[idx].overlays) { o in
                                        Text(o.text).font(.caption.bold()).foregroundColor(.white)
                                            .padding(.horizontal, 12).padding(.vertical, 10)
                                            .background(Color(red: 0.43, green: 0.34, blue: 0.96)).cornerRadius(8)
                                    }
                                } else {
                                    ForEach(["A plus...", "It's a l...", "In...", "It's a li...", "It's a li..."], id: \.self) { label in
                                        Text(label).font(.caption.bold()).foregroundColor(.white)
                                            .padding(.horizontal, 12).padding(.vertical, 10)
                                            .background(Color(red: 0.43, green: 0.34, blue: 0.96)).cornerRadius(8)
                                    }
                                }
                            }.padding(.horizontal, 12)
                        }
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 3) {
                                if idx >= 0 && idx < versions.count {
                                    ForEach(versions[idx].clips) { c in
                                        HStack(spacing: 6) {
                                            Text(c.label ?? "Clip " + String(c.clip_index + 1)).font(.caption2.bold()).foregroundColor(.white)
                                            Rectangle().fill(Color.pink).frame(width: 3, height: 26)
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(Color(red: 0.45, green: 0.08, blue: 0.16)).cornerRadius(6)
                                    }
                                } else {
                                    ForEach(0..<4, id: \.self) { _ in
                                        HStack(spacing: 28) {
                                            Rectangle().fill(Color.clear).frame(width: 10, height: 28)
                                            Rectangle().fill(Color.pink).frame(width: 3, height: 28)
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Color(red: 0.45, green: 0.08, blue: 0.16)).cornerRadius(6)
                                    }
                                }
                            }.padding(.horizontal, 12)
                        }
                    }
                    Rectangle().fill(Color.white).frame(width: 2, height: 125)
                }
                
                Text(status).font(.caption2).foregroundColor(.gray).lineLimit(1).padding(.horizontal)
                
                HStack(spacing: 8) {
                    Button { showRefPicker = true } label: {
                        Image(systemName: refImg == nil ? "photo.badge.plus" : "checkmark.circle.fill")
                            .font(.title3).foregroundColor(Color(red: 0.43, green: 0.34, blue: 0.96))
                    }
                    TextField("Explain edit or show style...", text: $prompt)
                        .font(.subheadline).padding(8).background(Color.white.opacity(0.1)).cornerRadius(18)
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
urls.removeAll(); durs.removeAll(); status = "Importing clips..."
for (i, it) in list.enumerated() {
if let data = try? await it.loadTransferable(type: Data.self) {
let u = FileManager.default.temporaryDirectory.appendingPathComponent("clip_" + String(i) + "_" + UUID().uuidString + ".mp4")
try? data.write(to: u)
let dur = (try? await AVURLAsset(url: u).load(.duration).seconds) ?? 5.0
urls.append(u); durs.append(dur)
}
}
items.removeAll()
if let first = urls.first { player = AVPlayer(url: first) }
status = "Imported " + String(urls.count) + " clip(s) — ready to edit!"
}
@MainActor func loadPreview(_ proj: TimelineProject) async {
if let out = try? await engine.render(urls: urls, proj: proj) {
preview = out; player = AVPlayer(url: out); player.play(); isPlaying = true
}
}
@MainActor func run() async {
guard !apiKey.isEmpty else { showKey = true; return }
busy = true; let p = prompt.isEmpty ? "Match reference image style" : prompt; prompt = ""; status = "Narrative (" + mode.rawValue + ") is cutting..."
do {
let proj = try await engine.edit(prompt: p, mode: mode, durs: durs, ref: refImg, cur: idx >= 0 ? versions[idx] : nil, key: apiKey)
versions.append(proj); idx = versions.count - 1; status = proj.assistant_reply ?? "Cut complete!"
await loadPreview(proj)
} catch { status = "Error: " + error.localizedDescription }
busy = false
}
}
