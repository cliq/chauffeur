import SwiftUI
import UIKit
import ImageIO

/// A zoomable image: pinch or double-tap to zoom, pan when zoomed. Fits the screen at rest.
struct ImagePreviewView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = LayoutReportingScrollView()
        scrollView.onLayout = { [weak coordinator = context.coordinator] view in coordinator?.layout(in: view) }
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image !== image {
            // The file changed on the Mac: show the new image at the current zoom.
            imageView.image = image
        }
        context.coordinator.layout(in: scrollView)
    }

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        private var laidOutBounds: CGSize = .zero
        private var laidOutImageSize: CGSize = .zero

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { center(in: scrollView) }

        /// Sizes the image view to fit the bounds at zoom 1. Only redone when the bounds or the image size change.
        func layout(in scrollView: UIScrollView) {
            guard let imageView, let image = imageView.image else { return }
            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 else { return }
            guard bounds != laidOutBounds || image.size != laidOutImageSize else { return }
            laidOutBounds = bounds; laidOutImageSize = image.size
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let zoom = scrollView.zoomScale
            scrollView.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
            // Large screenshots zoom until one image pixel fills a point.
            scrollView.maximumZoomScale = max(4, 1 / scale)
            scrollView.zoomScale = min(zoom, scrollView.maximumZoomScale)
            center(in: scrollView)
        }

        private func center(in scrollView: UIScrollView) {
            guard let imageView else { return }
            let bounds = scrollView.bounds.size, frame = imageView.frame.size
            scrollView.contentInset = UIEdgeInsets(
                top: max(0, (bounds.height - frame.height) / 2), left: max(0, (bounds.width - frame.width) / 2),
                bottom: 0, right: 0)
        }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView, let imageView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let zoom = min(scrollView.maximumZoomScale, 3)
                let size = CGSize(width: scrollView.bounds.width / zoom, height: scrollView.bounds.height / zoom)
                scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}

/// Reports layout passes so the image can be refitted when the view gets its real size or rotates.
private final class LayoutReportingScrollView: UIScrollView {
    var onLayout: ((UIScrollView) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}

enum ImageDecoding {
    /// Decodes at most `maxPixels` on the longest side so very large images don't exhaust memory.
    /// Orientation from EXIF is applied. Returns nil for data UIKit cannot decode.
    static func image(from data: Data, maxPixels: Int = 4096) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Pixel dimensions of the original image, for display.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 { swap(&width, &height) }
        return CGSize(width: width, height: height)
    }
}
