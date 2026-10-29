import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Puts a photo attachment into the person's photo library as stored (a JPEG, at most 2048 px).
/// Asks for add-only access: the app can add photos but never sees the library.
nonisolated enum PhotoSaver {
    enum SaveError: LocalizedError {
        case denied

        var errorDescription: String? {
            String(localized: "没有权限存储到相册。请在 iPhone「设置 › App › 随口记 › 照片」里允许「仅添加照片」。")
        }
    }

    static func save(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    /// What to tell the person afterwards.
    static func saveAndDescribe(_ data: Data?) async -> String {
        guard let data else { return String(localized: "没能读取。") }
        do {
            try await save(data)
            return String(localized: "已存储到相册")
        } catch {
            return error.localizedDescription
        }
    }
}

/// A photo for the share sheet, as the JPEG it's stored as.
struct SharedPhoto: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { $0.data }
            .suggestedFileName("photo.jpg")
    }
}

/// One photo the viewer can show; loaded when its page comes up.
struct ViewerPhoto: Identifiable {
    let id = UUID()
    let load: () -> Data?
    /// Keeps a marked-up version (the photo and its thumbnail, as JPEGs). Without it the viewer
    /// doesn't offer 标记.
    var replace: ((_ photo: Data, _ thumbnail: Data) -> Void)?
}

/// Full-screen photos: swipe between them, pinch or double-tap to zoom, mark up, save to Photos or share.
struct PhotoViewer: View {
    let photos: [ViewerPhoto]
    @State var index: Int
    let close: () -> Void
    @State private var loaded: [UUID: Data] = [:]
    @State private var message: String?
    @State private var markingUp: Markup?

    private struct Markup: Identifiable {
        let id = UUID()
        let photo: ViewerPhoto
        let image: UIImage
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { offset, photo in
                    ZoomableImage(data: loaded[photo.id])
                        .ignoresSafeArea()
                        .tag(offset)
                        .task { load(photo) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(.black)
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark", action: close)
                }
                if photos.count > 1 {
                    ToolbarItem(placement: .principal) {
                        Text(verbatim: "\(index + 1) / \(photos.count)")
                            .font(.subheadline.monospacedDigit())
                    }
                }
                if currentPhoto?.replace != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("标记", systemImage: "pencil.tip.crop.circle") { startMarkup() }
                            .disabled(current == nil)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            // Named buttons rather than toolbar icons: saving is what people come here for.
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    if let data = current {
                        ShareLink(item: SharedPhoto(data: data),
                                  preview: SharePreview(Text("照片"), image: Image(uiImage: UIImage(data: data) ?? UIImage()))) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("存储到相册", systemImage: "square.and.arrow.down") {
                        let data = current
                        Task { message = await PhotoSaver.saveAndDescribe(data) }
                    }
                    .disabled(current == nil)
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.bottom, 8)
            }
            .transientMessage($message)
            .fullScreenCover(item: $markingUp) { markup in
                PhotoMarkupView(image: markup.image) { marked in keep(marked, for: markup.photo) }
            }
        }
    }

    /// Opens the viewer over whatever is showing. UIKit presents it, over the page rather than in
    /// place of it, as it does the camera: in SwiftUI's full-screen cover, the viewer's dark look
    /// flashed across the page beneath as it opened, and the page "disappeared" behind it, so a
    /// note jumped back to its last entry when the photo was closed.
    static func present(_ photos: [ViewerPhoto], at index: Int) {
        guard let top = UIApplication.shared.topViewController else { return }
        weak var shown: UIViewController?
        let host = UIHostingController(rootView: PhotoViewer(photos: photos, index: index) { shown?.dismiss(animated: true) })
        shown = host
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .black
        host.modalPresentationStyle = .overFullScreen
        // The status bar turns light over the black, as it would for a full-screen presentation.
        host.modalPresentationCapturesStatusBarAppearance = true
        top.present(host, animated: true)
    }

    private var currentPhoto: ViewerPhoto? {
        photos.indices.contains(index) ? photos[index] : nil
    }

    private var current: Data? {
        currentPhoto.flatMap { loaded[$0.id] }
    }

    private func startMarkup() {
        guard let photo = currentPhoto, let data = current, let image = UIImage(data: data) else { return }
        markingUp = Markup(photo: photo, image: image)
    }

    /// The marked-up photo replaces the original, here and wherever it's kept.
    private func keep(_ marked: UIImage, for photo: ViewerPhoto) {
        Task {
            let prepared = await Task.detached(priority: .userInitiated) { ImageTools.prepare(marked) }.value
            guard let prepared else {
                message = String(localized: "没能保存标记。")
                return
            }
            photo.replace?(prepared.full, prepared.thumbnail)
            loaded[photo.id] = prepared.full
            message = String(localized: "已保存标记")
        }
    }

    private func load(_ photo: ViewerPhoto) {
        guard loaded[photo.id] == nil, let data = photo.load() else { return }
        loaded[photo.id] = data
    }
}

/// A photo that fits the screen and zooms (pinch, or double-tap in and out).
private struct ZoomableImage: UIViewRepresentable {
    let data: Data?

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let imageView = context.coordinator.imageView
        if context.coordinator.data != data {
            context.coordinator.data = data
            imageView.image = data.flatMap(UIImage.init(data:))
            scroll.zoomScale = 1
        }
        imageView.accessibilityLabel = String(localized: "照片")
        imageView.isAccessibilityElement = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        var data: Data?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}
