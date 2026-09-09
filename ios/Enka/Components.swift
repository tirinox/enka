import SwiftUI

/// The small pieces more than one screen needs.
///
/// Nothing here talks to the server or holds a decision — they are shapes.
/// Anything with an opinion about what Enka does belongs in `shared/`, where
/// the Mac gets it too.

// MARK: - Tags

/// A tag, in the colour it was given. Tapped, it is a filter or a choice;
/// untapped it is a label, which is why `action` is optional.
struct TagChip: View {
    let name: String
    var color: String?
    var selected = false
    var action: (() -> Void)?

    /// Parsed leniently: a bad value is a tag that looks like the others, which
    /// is exactly what it looked like before somebody typed a colour at all.
    private var tint: Color {
        guard let color, let parsed = Color(hex: color) else { return Theme.textFaint }
        return parsed
    }

    var body: some View {
        let label = Text(name)
            .font(.footnote.weight(.medium))
            .foregroundStyle(selected ? Theme.textInverse : tint)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Capsule().fill(selected ? tint : tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(selected ? 0 : 0.3), lineWidth: 1))
            .contentShape(Capsule())

        if let action {
            Button(action: action) { label }.buttonStyle(.plain)
        } else {
            label
        }
    }
}

/// A tag on a card being edited: the name, and the × that takes it off.
struct RemovableTagChip: View {
    let name: String
    var color: String?
    let remove: () -> Void

    private var tint: Color {
        guard let color, let parsed = Color(hex: color) else { return Theme.textFaint }
        return parsed
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(tint)
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .frame(height: 30)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 1))
    }
}

/// The dot beside a tag's name. A ring rather than a grey disc when there is no
/// colour: "no colour chosen" and "the colour is grey" are different things,
/// and #8a8f98 is in the palette.
struct ColourDot: View {
    let hex: String?
    var diameter: CGFloat = 12

    var body: some View {
        Group {
            if let hex, let colour = Color(hex: hex) {
                Circle().fill(colour)
            } else {
                Circle().strokeBorder(Theme.textFaint, lineWidth: 1)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The eight the web client and the Mac offer, and an off switch: pressing the
/// one already chosen clears the colour, which is the only way back to "no
/// colour" and the same gesture both other clients use for it.
struct PalettePicker: View {
    @Binding var selected: String?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(TagStore.palette, id: \.self) { hex in
                Button {
                    selected = selected == hex ? nil : hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex) ?? Theme.textFaint)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .strokeBorder(Theme.text, lineWidth: selected == hex ? 2 : 0)
                                .padding(-3)
                        )
                        .contentShape(Circle().inset(by: -6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Stars

/// The card's own 1–5 grade, which is the user's opinion of it rather than the
/// scheduler's. Tapping the star already lit clears it — there is no other way
/// back to "ungraded", and a card arrives that way.
struct StarRatingPicker: View {
    @Binding var rating: Int?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    rating = (rating == value) ? nil : value
                } label: {
                    Image(systemName: (rating ?? 0) >= value ? "star.fill" : "star")
                        .font(.system(size: 17))
                        .foregroundStyle((rating ?? 0) >= value ? Theme.hard : Theme.textFaint)
                        .frame(width: 30, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if rating != nil {
                Button("Clear") { rating = nil }
                    .font(.footnote)
                    .foregroundStyle(Theme.textFaint)
                    .padding(.leading, 4)
            }
        }
    }
}

// MARK: - Layout

/// A row of chips that wraps.
///
/// Tags are the one thing in the app whose width is somebody else's decision —
/// a card can carry `de` and `separable verbs` in the same breath — and a
/// horizontal scroller hides whichever ones do not fit, which for a filter is
/// the same as not having them.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if next > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
                row.indices = [index]
                row.width = size.width
                row.height = size.height
            } else {
                row.indices.append(index)
                row.width = next
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Chrome

/// A screen with nothing on it yet, said in words rather than left blank. An
/// empty list and a failed load look identical otherwise, and the remedies are
/// nothing alike.
struct EmptyNotice: View {
    let symbol: String
    let message: String
    var tint: Color = Theme.textFaint
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(SoftButtonStyle())
                    .fixedSize()
                    .padding(.top, 2)
            }
        }
        .foregroundStyle(tint)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The heading over a group of things on a screen that is not a `Form`.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textFaint)
    }
}

/// A number and what it counts. The stats screen is five of these and nothing
/// else above the fold.
struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

/// One line of the app's own voice — an error, or the fact that something
/// saved. Never a dialog: nothing on these screens is important enough to
/// stop somebody, and a phone has the room to simply say it.
struct NoticeLine: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = Theme.danger

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A text view that grows with what is typed into it, with a placeholder —
/// the two things `TextEditor` does not do on its own.
struct GrowingTextField: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = .body
    var minHeight: CGFloat = 88

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(Theme.textFaint)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(font)
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
        }
    }
}
