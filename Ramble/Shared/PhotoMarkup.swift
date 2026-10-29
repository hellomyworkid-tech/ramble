import PaperKit
import PencilKit
import SwiftUI
import UIKit

/// Draw on a photo, write on it, add arrows and shapes: the system's markup tools (PaperKit).
/// 完成 hands back the photo with the marks drawn into it, at the photo's own size.
struct PhotoMarkupView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var canvas = MarkupCanvas.Model()
    @State private var isSaving = false
    @State private var confirmsDiscard = false

    var body: some View {
        NavigationStack {
            MarkupCanvas(image: image, model: canvas)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("标记")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", systemImage: "xmark", role: .cancel) {
                            if canvas.hasChanges { confirmsDiscard = true } else { dismiss() }
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("撤销", systemImage: "arrow.uturn.backward") { canvas.undo() }
                            .disabled(!canvas.canUndo)
                        Button("重做", systemImage: "arrow.uturn.forward") { canvas.redo() }
                            .disabled(!canvas.canRedo)
                        Button("添加文字或形状", systemImage: "plus") { canvas.showInsertMenu() }
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成", systemImage: "checkmark", role: .confirm) {
                            Task { await finish() }
                        }
                        .disabled(isSaving)
                    }
                }
                .confirmationDialog("放弃这次标记？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                    Button("放弃标记", role: .destructive) { dismiss() }
                }
        }
        // Dark like the photo viewer it opens from, which UIKit presents: a SwiftUI cover doesn't take that on.
        .preferredColorScheme(.dark)
    }

    private func finish() async {
        isSaving = true
        defer { isSaving = false }
        if canvas.hasChanges, let marked = await canvas.render() {
            onDone(marked)
        }
        dismiss()
    }
}

/// The canvas: the photo underneath, PaperKit's markup on top, and the tool picker below.
struct MarkupCanvas: UIViewControllerRepresentable {
    let image: UIImage
    let model: Model

    /// What the SwiftUI toolbar needs from the canvas.
    @Observable
    final class Model {
        fileprivate weak var controller: MarkupCanvasController?
        fileprivate(set) var hasChanges = false
        fileprivate(set) var canUndo = false
        fileprivate(set) var canRedo = false

        func undo() { controller?.undoManager?.undo() }
        func redo() { controller?.undoManager?.redo() }
        func showInsertMenu() { controller?.showInsertMenu() }
        func render() async -> UIImage? { await controller?.render() }
    }

    func makeUIViewController(context: Context) -> MarkupCanvasController {
        let controller = MarkupCanvasController(image: image)
        controller.onChange = { [weak model, weak controller] in
            guard let model, let controller else { return }
            model.hasChanges = controller.hasChanges
            model.canUndo = controller.undoManager?.canUndo ?? false
            model.canRedo = controller.undoManager?.canRedo ?? false
        }
        model.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: MarkupCanvasController, context: Context) {}
}

final class MarkupCanvasController: UIViewController, PaperMarkupViewController.Delegate {
    let image: UIImage
    var onChange: () -> Void = {}
    private(set) var hasChanges = false
    private var paper: PaperMarkupViewController?
    private let toolPicker = PKToolPicker()
    /// PaperKit takes its undo manager from the responder chain, so this one is the canvas's
    /// (the tool picker's undo and redo buttons use it too).
    private let undo = UndoManager()
    /// The markup's own coordinates: the photo fitted to the screen, so pens and text come out
    /// at their usual sizes. Marks are vectors, and stay sharp drawn into the full-size photo.
    private var canvasBounds = CGRect.zero
    private var fittedSize = CGSize.zero
    /// The empty canvas: undoing back to it leaves nothing to save.
    private var blank: PaperMarkup?

    init(image: UIImage) {
        self.image = image.upright
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override var undoManager: UndoManager? { undo }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0, size != fittedSize else { return }
        fittedSize = size
        if paper == nil { makeCanvas(fitting: size) }
        guard let paper else { return }
        // The whole photo, zooming in from there but not out.
        let fit = min(size.width / canvasBounds.width, size.height / canvasBounds.height)
        paper.zoomRange = fit...(fit * 6)
        paper.setContentVisibleFrame(canvasBounds, animated: false)
    }

    private func makeCanvas(fitting size: CGSize) {
        let aspect = image.size.width / max(image.size.height, 1)
        let width = min(size.width, size.height * aspect)
        canvasBounds = CGRect(x: 0, y: 0, width: width.rounded(), height: (width / aspect).rounded())

        let blank = PaperMarkup(bounds: canvasBounds)
        self.blank = blank
        let paper = PaperMarkupViewController(markup: blank, supportedFeatureSet: .latest)
        paper.delegate = self
        let photo = UIImageView(image: image)
        photo.contentMode = .scaleToFill
        photo.frame = canvasBounds
        paper.contentView = photo
        addChild(paper)
        paper.view.frame = view.bounds
        paper.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(paper.view)
        paper.didMove(toParent: self)
        self.paper = paper

        // Ink shows as chosen on the photo: no dark-mode swapping of black and white.
        paper.overrideUserInterfaceStyle = .light
        paper.view.backgroundColor = .black
        toolPicker.colorUserInterfaceStyle = .light
        toolPicker.addObserver(paper)
        paper.pencilKitResponderState.activeToolPicker = toolPicker
        paper.pencilKitResponderState.toolPickerVisibility = .visible
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        paper?.becomeFirstResponder()
    }

    /// Text, arrows, shapes and the like, from the system's own menu.
    func showInsertMenu() {
        guard let paper else { return }
        let menu = MarkupEditViewController(supportedFeatureSet: .latest)
        menu.delegate = paper
        menu.modalPresentationStyle = .popover
        if let popover = menu.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.maxX - 95, y: view.safeAreaInsets.top, width: 1, height: 1)
            popover.permittedArrowDirections = .up
            popover.delegate = self
        }
        present(menu, animated: true)
    }

    /// The photo at its own size with the marks drawn over it.
    func render() async -> UIImage? {
        guard let markup = paper?.markup, let photo = image.cgImage, canvasBounds.width > 0 else { return nil }
        let size = CGSize(width: photo.width, height: photo.height)
        guard let context = CGContext(data: nil, width: photo.width, height: photo.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(photo, in: CGRect(origin: .zero, size: size))
        // PaperKit draws top-down in the canvas's own units: flip, and scale the canvas up to the photo.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: size.width / canvasBounds.width, y: -size.height / canvasBounds.height)
        await markup.draw(in: context, frame: canvasBounds)
        guard let result = context.makeImage() else { return nil }
        return UIImage(cgImage: result)
    }

    // MARK: PaperMarkupViewController.Delegate

    func paperMarkupViewControllerDidChangeMarkup(_ paperMarkupViewController: PaperMarkupViewController) {
        hasChanges = paperMarkupViewController.markup != blank
        onChange()
    }
}

extension MarkupCanvasController: UIPopoverPresentationControllerDelegate {
    /// A small menu by the + button, rather than a sheet over the photo.
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}

private extension UIImage {
    /// The same picture with its pixels the right way up, so its `cgImage` can be drawn as is.
    var upright: UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(at: .zero) }
    }
}
