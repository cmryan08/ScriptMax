import AppKit

struct PromptLayout {
    let lines: [String]
    let fontSize: CGFloat
    let wordCount: Int
    let requiredWidth: CGFloat

    static func font(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
    static func width(_ text: String, size: CGFloat) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font(size)]).width)
    }
    static func fit(words: [String], maximumWords: Int, width: CGFloat, preferredSize: CGFloat, minimumSize: CGFloat) -> PromptLayout {
        let available = Array(words.prefix(maximumWords))
        guard !available.isEmpty else { return PromptLayout(lines: [""], fontSize: preferredSize, wordCount: 0, requiredWidth: 0) }
        let minimum = min(preferredSize, max(8, minimumSize))
        func candidate(_ count: Int, _ size: CGFloat) -> PromptLayout {
            let selected = Array(available.prefix(count))
            if selected.count == 1 {
                return PromptLayout(lines: [selected[0]], fontSize: size, wordCount: 1, requiredWidth: Self.width(selected[0], size: size))
            }
            var best: PromptLayout?
            for split in 1..<selected.count {
                let lines = [selected.prefix(split).joined(separator: " "), selected.dropFirst(split).joined(separator: " ")]
                let measured = lines.map { Self.width($0, size: size) }.max() ?? 0
                if best == nil || measured < best!.requiredWidth {
                    best = PromptLayout(lines: lines, fontSize: size, wordCount: selected.count, requiredWidth: measured)
                }
            }
            return best!
        }
        // Reduce the count at full size before using the permitted size range.
        let normalMinimum = min(4, available.count)
        for count in stride(from: available.count, through: normalMinimum, by: -1) {
            let layout = candidate(count, preferredSize)
            if layout.requiredWidth <= width { return layout }
        }
        for count in stride(from: available.count, through: normalMinimum, by: -1) {
            let atMinimum = candidate(count, minimum)
            if atMinimum.requiredWidth <= width {
                let atPreferred = candidate(count, preferredSize)
                let size = max(minimum, min(preferredSize, floor(preferredSize * width / max(1, atPreferred.requiredWidth) * 10) / 10))
                let fitted = candidate(count, size)
                if fitted.requiredWidth <= width { return fitted }
                return atMinimum
            }
        }
        // Exceptionally long words appear alone or with fewer neighbors. Nothing
        // is removed from the script; withheld words appear after speech advances.
        if normalMinimum > 1 {
            for count in stride(from: normalMinimum - 1, through: 1, by: -1) {
                let layout = candidate(count, preferredSize)
                if layout.requiredWidth <= width { return layout }
            }
        }
        // One unusually long word expands the box instead of becoming tiny.
        return candidate(1, preferredSize)
    }
}
