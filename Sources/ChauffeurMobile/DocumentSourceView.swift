import SwiftUI
import UIKit

/// Read-only, selectable, searchable text for the raw view of a document.
struct DocumentSourceView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isFindInteractionEnabled = true
        view.dataDetectorTypes = []
        view.alwaysBounceVertical = true
        view.adjustsFontForContentSizeCategory = true
        view.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.textColor = .label
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        let offset = view.contentOffset
        view.text = text
        view.layoutIfNeeded()
        let maxY = max(0, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        view.setContentOffset(CGPoint(x: offset.x, y: min(offset.y, maxY)), animated: false)
    }
}
