@MainActor
struct ContentView: View {
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
                        PhotosPicker(selection: $items, maxSelectionCount: 12, matching: .videos) {
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
                            PhotosPicker(selection: $items, maxSelectionCount: 12, matching: .videos) {
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
                    PhotosPicker(selection: $refItem, matching: .images) {
                        Image(systemName: refImg == nil ? "photo.badge.plus" : "checkmark.circle.fill")
                            .font(.title3).foregroundColor(Color(red: 0.43, green: 0.34, blue: 0.96))
                    }
                    TextField("Explain edit or show style (e.g. 'In his prime' beat cut)...", text: $prompt)
                        .font(.subheadline).padding(8).background(Color.white.opacity(0.1)).cornerRadius(18)
                    Button { Task { await run() } } label: {
                        if busy { ProgressView().tint(.white) }
                        else { Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundColor(Color(red: 0.43, green: 0.34, blue: 0.96)) }
                    }.disabled(urls.isEmpty || (prompt.isEmpty && refImg == nil) || busy)
                }.padding(.horizontal).padding(.bottom, 6)
            }
        }
.onChange(of: items) { _, list in Task { await load(list) } }
.onChange(of: refItem) { _, it in Task { if let d = try? await it?.loadTransferable(type: Data.self) { refImg = UIImage(data: d) } } }
.sheet(isPresented: $showKey) {
NavigationStack { Form { SecureField("Free Gemini API Key (AIza...)", text: $apiKey) }.navigationTitle("AI Settings").toolbar { Button("Done") { showKey = false } } }.presentationDetents([.medium])
}
}
@MainActor func load(_ list: [PhotosPickerItem]) async {
urls.removeAll(); durs.removeAll(); status = "Importing clips..."
for it in list {
if let video = try? await it.loadTransferable(type: VideoFile.self) {
let u = video.url
let dur = (try? await AVURLAsset(url: u).load(.duration).seconds) ?? 5.0
urls.append(u); durs.append(dur)
}
}
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
