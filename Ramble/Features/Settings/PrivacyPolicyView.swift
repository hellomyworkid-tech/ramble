import SwiftUI

/// Where people get in touch. The same address is in the privacy policy and on the support page
/// (website/), so change it in all three when it changes.
enum AppLinks {
    static let contactEmail = "hellolink@icloud.com"
    static var hasContactEmail: Bool { contactEmail.contains("@") && !contactEmail.contains("{{") }

    static let website = "https://hellomyworkid-tech.github.io/ramble/"
    /// Ramble is open source (MIT).
    static let sourceCode = URL(string: "https://github.com/hellomyworkid-tech/Ramble")!
    /// The published policy, in the app's language (the same text as the bundled one).
    static var privacyPolicy: URL {
        URL(string: website + (AppLanguage.isChinese ? "privacy.html" : "privacy-en.html"))!
    }
}

/// The privacy policy, read from the bundled Markdown (Resources/Legal) in the app's language.
/// The website pages are built from the same files, so the two always say the same thing.
struct PrivacyPolicyView: View {
    var body: some View {
        LegalDocumentView(blocks: LegalDocument.load("privacy"), title: "隐私政策")
    }
}

/// The licenses of the open-source code inside the app (scripts/make_licenses.py writes them).
/// Shown as plain text: licence texts are full of characters Markdown would take as formatting.
struct LicensesView: View {
    var body: some View {
        LegalDocumentView(blocks: LegalDocument.load("licenses", localized: false), title: "开源许可", formatsText: false)
    }
}

struct LegalDocumentView: View {
    let blocks: [LegalDocument.Block]
    let title: LocalizedStringResource
    var formatsText = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .title(let text):
                        Text(text).font(.title2.weight(.bold))
                    case .heading(let text):
                        Text(text).font(.headline).padding(.top, 8)
                    case .paragraph(let text):
                        Text(formatsText ? LegalDocument.inline(text) : AttributedString(text)).font(.subheadline)
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "•")
                            Text(formatsText ? LegalDocument.inline(text) : AttributedString(text))
                        }
                        .font(.subheadline)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .navigationTitle(Text(title))
        .navigationBarTitleDisplayMode(.inline)
    }
}

nonisolated enum LegalDocument {
    enum Block {
        case title(String), heading(String), paragraph(String), bullet(String)
    }

    /// `name-zh-Hans.md` or `name-en.md`, whichever matches the app's language; `name.md` when not `localized`.
    static func load(_ name: String, localized: Bool = true) -> [Block] {
        let language = AppLanguage.isChinese ? "zh-Hans" : "en"
        guard let url = Bundle.main.url(forResource: localized ? "\(name)-\(language)" : name, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text.replacingOccurrences(of: "{{CONTACT_EMAIL}}", with: AppLinks.contactEmail))
    }

    /// Just what the policy uses: a title, headings, paragraphs and bullet lists.
    static func parse(_ text: String) -> [Block] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let line = String(line)
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .title(String(line.dropFirst(2))) }
            if line.hasPrefix("- ") { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    /// **Bold** and links inside a line.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
