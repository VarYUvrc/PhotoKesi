import SwiftUI

/// UIScrollView ベースのズームビューを SwiftUI から簡潔に扱うためのラッパー。
/// - Note: ズーム倍率は外部と双方向バインディングし、親ビュー側でページ送りなどの挙動制御に利用できる。
struct ZoomableImageView: View {
    let image: UIImage
    @Binding var zoomScale: CGFloat

    var body: some View {
        ZoomScrollView(image: image, zoomScale: $zoomScale)
    }
}

private struct ZoomScrollView: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomScale: CGFloat

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.backgroundColor = .clear
        scrollView.isScrollEnabled = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isUserInteractionEnabled = true

        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        if let imageView = context.coordinator.imageView, imageView.image !== image {
            imageView.image = image
        }

        if abs(uiView.zoomScale - zoomScale) > 0.01 {
            uiView.setZoomScale(zoomScale, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var zoomScale: Binding<CGFloat>
        weak var imageView: UIImageView?

        init(zoomScale: Binding<CGFloat>) {
            self.zoomScale = zoomScale
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let scale = scrollView.zoomScale
            zoomScale.wrappedValue = scale
            scrollView.isScrollEnabled = scale > 1.01
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            let point = gesture.location(in: gesture.view)
            let nextScale: CGFloat = scrollView.zoomScale > 1.01 ? 1.0 : min(scrollView.maximumZoomScale, scrollView.zoomScale * 2)

            if nextScale == 1.0 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let zoomRect = rect(for: scrollView, scale: nextScale, center: point)
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }

        private func rect(for scrollView: UIScrollView, scale: CGFloat, center: CGPoint) -> CGRect {
            var zoomRect = CGRect.zero
            zoomRect.size.height = scrollView.bounds.height / scale
            zoomRect.size.width = scrollView.bounds.width / scale
            zoomRect.origin.x = center.x - (zoomRect.size.width / 2.0)
            zoomRect.origin.y = center.y - (zoomRect.size.height / 2.0)
            return zoomRect
        }
    }
}
