import SwiftUI
import UIKit

/// What's being said, while it's being said: shown in place of the text field during a
/// recording. It grows with the text up to `maxLines`, then scrolls and follows the newest
/// words. Scrolling up to read earlier words stops the following (the field used to stay put
/// while the words kept arriving below, which looked as if dictation had stopped); scrolling
/// back down, or the arrow, picks it up again. Not editable: edits would be overwritten by the
/// next words anyway, so the text field comes back when the recording ends.
struct LiveTranscript: View {
    let text: String
    let placeholder: LocalizedStringResource
    var minLines = 1
    var maxLines = 6
    var textStyle: UIFont.TextStyle = .body

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var follows = true
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let line = UIFont.preferredFont(forTextStyle: textStyle).lineHeight
        ScrollView {
            Group {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary)
                } else {
                    Text(text)
                }
            }
            .font(Font(UIFont.preferredFont(forTextStyle: textStyle)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollPosition($position)
        .scrollIndicators(.automatic)
        .frame(height: min(max(contentHeight, line * CGFloat(minLines)), line * CGFloat(maxLines)))
        // Only the person's own scrolling changes whether it follows; growing text doesn't.
        .onScrollPhaseChange { _, phase, context in
            switch phase {
            case .interacting, .tracking, .decelerating:
                follows = false
            case .idle:
                let geometry = context.geometry
                follows = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 6
            default:
                break
            }
        }
        .onChange(of: text) {
            if follows { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !follows {
                Button("回到最新", systemImage: "arrow.down.circle.fill") {
                    follows = true
                    withAnimation { position.scrollTo(edge: .bottom) }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.tint)
                .buttonStyle(.borderless)
                .background(Circle().fill(.background))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: follows)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("正在识别"))
        .accessibilityValue(Text(text))
    }
}
