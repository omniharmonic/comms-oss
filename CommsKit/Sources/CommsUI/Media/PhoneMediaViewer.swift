#if os(iOS)
import AVKit
import CommsClient
import CommsCore
import PrismModels
import UIKit
import UniformTypeIdentifiers

/// The full-screen photo / video viewer, as Messages and Photos do it on iPhone:
/// - opens at once over the bubble's thumbnail (spinner until the full picture is in);
/// - swipe down (or up) to close: the picture follows the finger, shrinks a little and the
///   background fades; let go far enough or flick and it closes, otherwise it springs back;
/// - pinch and double-tap to zoom; while zoomed a drag pans the picture, never closes it;
/// - tap to hide / show the bar (black background without it); Close (X) and Share;
/// - a failure is always shown (message + Try Again), never a silent nothing.
/// Videos play in an embedded `AVPlayerViewController` and close the same way.
@MainActor
final class PhoneMediaViewerController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    enum Phase: Equatable {
        case loading
        case image
        case video
        case failed(String)
    }

    let attachment: CommsAttachment
    private let fetcher: MediaFetcher
    private(set) var phase: Phase = .loading { didSet { phaseChanged() } }
    private var prepared: PreparedMedia?
    private var task: Task<Void, Never>?
    private var chromeHidden = false
    private var statusObservation: NSKeyValueObservation?

    private let backdrop = UIView()
    /// Everything the drag moves and scales (the zoomable picture or the player).
    private let stage = UIView()
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private var playerController: AVPlayerViewController?
    private let spinner = UIActivityIndicatorView(style: .large)
    private let errorStack = UIStackView()
    private let errorLabel = UILabel()
    private let retryButton = UIButton(configuration: .bordered())
    private let topBar = UIStackView()
    private let closeButton = UIButton(configuration: .glass())
    private let shareButton = UIButton(configuration: .glass())
    private let dismissPan = UIPanGestureRecognizer()

    init(attachment: CommsAttachment, fetcher: MediaFetcher, placeholder: CGImage?) {
        self.attachment = attachment
        self.fetcher = fetcher
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        modalPresentationCapturesStatusBarAppearance = true
        if let placeholder { imageView.image = UIImage(cgImage: placeholder) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isVideo: Bool { attachment.kind == .video }

    /// Presents the viewer for `attachment` over whatever is on screen (a Details sheet too).
    static func present(_ attachment: CommsAttachment, fetcher: MediaFetcher, loader: MediaLoader) {
        guard let top = topViewController(), !(top is PhoneMediaViewerController) else { return }
        let thumb = [attachment.thumbToken, attachment.mediaToken].compactMap { $0 }.lazy.compactMap { loader.cached($0) }.first
        let c = PhoneMediaViewerController(attachment: attachment, fetcher: fetcher, placeholder: thumb?.cgImage)
        top.present(c, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows) + scenes.flatMap(\.windows)
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    // MARK: View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "media-viewer"
        view.accessibilityViewIsModal = true

        backdrop.backgroundColor = .systemBackground
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)

        stage.frame = view.bounds
        stage.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(stage)

        scroll.frame = stage.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        stage.addSubview(scroll)

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = isVideo ? "Video" : "Photo"
        imageView.accessibilityIdentifier = "media-viewer-image"
        imageView.accessibilityTraits = .image
        scroll.addSubview(imageView)

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.accessibilityIdentifier = "media-viewer-loading"
        view.addSubview(spinner)

        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.font = .preferredFont(forTextStyle: .body)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = .secondaryLabel
        errorLabel.accessibilityIdentifier = "media-viewer-error"
        retryButton.configuration?.title = "Try Again"
        retryButton.accessibilityIdentifier = "media-viewer-retry"
        retryButton.addAction(UIAction { [weak self] _ in self?.load() }, for: .primaryActionTriggered)
        let icon = UIImageView(image: UIImage(systemName: isVideo ? "video.slash" : "photo.badge.exclamationmark"))
        icon.preferredSymbolConfiguration = .init(textStyle: .largeTitle)
        icon.tintColor = .secondaryLabel
        errorStack.axis = .vertical
        errorStack.alignment = .center
        errorStack.spacing = 12
        errorStack.addArrangedSubview(icon)
        errorStack.addArrangedSubview(errorLabel)
        errorStack.addArrangedSubview(retryButton)
        errorStack.translatesAutoresizingMaskIntoConstraints = false
        errorStack.isHidden = true
        view.addSubview(errorStack)

        closeButton.configuration?.image = UIImage(systemName: "xmark")
        closeButton.configuration?.preferredSymbolConfigurationForImage = .init(pointSize: 17, weight: .semibold)
        closeButton.configuration?.baseForegroundColor = .label
        closeButton.accessibilityLabel = "Close"
        closeButton.accessibilityIdentifier = "media-viewer-close"
        closeButton.addAction(UIAction { [weak self] _ in self?.close(animated: true) }, for: .primaryActionTriggered)
        shareButton.configuration?.image = UIImage(systemName: "square.and.arrow.up")
        shareButton.configuration?.preferredSymbolConfigurationForImage = .init(pointSize: 17, weight: .semibold)
        shareButton.configuration?.baseForegroundColor = .label
        shareButton.accessibilityLabel = "Share"
        shareButton.accessibilityIdentifier = "media-viewer-share"
        shareButton.isEnabled = false
        shareButton.addAction(UIAction { [weak self] _ in self?.share() }, for: .primaryActionTriggered)
        let spacer = UIView()
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.addArrangedSubview(closeButton)
        topBar.addArrangedSubview(spacer)
        topBar.addArrangedSubview(shareButton)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            errorStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),
            topBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            topBar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 4),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            shareButton.widthAnchor.constraint(equalToConstant: 44),
            shareButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        // Tap: hide / show the bar. Double tap: zoom in at the finger, or back out.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: doubleTap)
        stage.addGestureRecognizer(tap)
        // One finger only: a pinch never turns into a dismissal.
        dismissPan.addTarget(self, action: #selector(panned(_:)))
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.delegate = self
        view.addGestureRecognizer(dismissPan)

        phaseChanged()
        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.zoomScale <= scroll.minimumZoomScale + 0.001 { fitImage() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        task?.cancel()
        playerController?.player?.pause()
        statusObservation = nil
        if let prepared { QuickLookTempFile.remove(prepared.url) }
        prepared = nil
    }

    override var prefersStatusBarHidden: Bool { chromeHidden }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var prefersHomeIndicatorAutoHidden: Bool { chromeHidden }

    override func accessibilityPerformEscape() -> Bool {
        close(animated: true)
        return true
    }

    // MARK: Loading

    private func load() {
        task?.cancel()
        phase = .loading
        let a = attachment, fetcher = fetcher
        task = Task { [weak self] in
            do {
                guard let media = try await QuickLookPreparer.prepareTyped(a, fetch: fetcher) else {
                    throw CommsError.mediaExpired // nothing to fetch
                }
                guard let self, !Task.isCancelled else { return QuickLookTempFile.remove(media.url) }
                if let old = self.prepared { QuickLookTempFile.remove(old.url) }
                self.prepared = media
                if media.type.conforms(to: .audiovisualContent) || (a.kind == .video && !media.type.conforms(to: .image)) {
                    self.showVideo(media.url)
                } else {
                    let url = media.url
                    let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                        guard let data = try? Data(contentsOf: url) else { return nil }
                        return MediaImage(data: data, maxPixelSize: 4096)?.cgImage
                    }.value
                    guard !Task.isCancelled else { return }
                    guard let image else { throw MediaUndecodable(video: false) }
                    self.showImage(image)
                }
            } catch {
                guard let self, !Task.isCancelled, !QuickLookPreparer.isCancellation(error) else { return }
                self.phase = .failed(MediaOpenFailure.message(for: error, kind: a.kind))
            }
        }
    }

    private func showImage(_ image: CGImage) {
        imageView.image = UIImage(cgImage: image)
        imageView.accessibilityValue = "full"
        phase = .image
        fitImage()
    }

    private func showVideo(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let pc = AVPlayerViewController()
        pc.player = player
        pc.view.backgroundColor = .clear
        pc.view.frame = stage.bounds
        pc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pc.view.accessibilityIdentifier = "media-viewer-video"
        addChild(pc)
        stage.addSubview(pc.view)
        pc.didMove(toParent: self)
        playerController = pc
        scroll.isHidden = true
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor [weak self] in
                if failed { self?.phase = .failed(MediaOpenFailure.message(for: MediaUndecodable(video: true), kind: .video)) }
            }
        }
        phase = .video
        player.play()
    }

    private func phaseChanged() {
        guard isViewLoaded else { return }
        switch phase {
        case .loading:
            spinner.startAnimating()
            errorStack.isHidden = true
            imageView.alpha = 1
            imageView.accessibilityValue = "preview"
        case .image, .video:
            spinner.stopAnimating()
            errorStack.isHidden = true
            imageView.alpha = 1
        case .failed(let message):
            spinner.stopAnimating()
            errorLabel.text = message
            errorStack.isHidden = false
            // The thumbnail stays behind a dim veil; the message is what matters.
            imageView.alpha = 0.25
            playerController?.view.isHidden = true
            UIAccessibility.post(notification: .screenChanged, argument: errorLabel)
        }
        shareButton.isEnabled = phase == .image || phase == .video
    }

    // MARK: Zoom

    /// The picture fitted to the screen at zoom 1, centred.
    private func fitImage() {
        let bounds = scroll.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let size = imageView.image?.size ?? CGSize(width: 4, height: 3)
        let s = min(bounds.width / max(1, size.width), bounds.height / max(1, size.height))
        let fitted = CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
        scroll.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scroll.contentSize = fitted
        centerImage()
    }

    private func centerImage() {
        let b = scroll.bounds.size, f = imageView.frame.size
        let x = max(0, (b.width - f.width) / 2), y = max(0, (b.height - f.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { phase == .image || phase == .loading ? imageView : nil }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    var isZoomed: Bool { scroll.zoomScale > scroll.minimumZoomScale + 0.01 }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard phase == .image else { return }
        if isZoomed {
            scroll.setZoomScale(1, animated: true)
        } else {
            let p = g.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
            scroll.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func tapped() {
        guard phase != .video else { return } // the player's own controls take taps
        setChromeHidden(!chromeHidden)
    }

    private func setChromeHidden(_ hidden: Bool) {
        chromeHidden = hidden
        UIView.animate(withDuration: 0.2) {
            self.topBar.alpha = hidden ? 0 : 1
            self.backdrop.backgroundColor = hidden ? .black : .systemBackground
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }

    // MARK: Swipe to close

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === dismissPan else { return true }
        let v = dismissPan.velocity(in: view)
        return MediaDismissal.begins(velocity: CGSize(width: v.x, height: v.y), zoomed: isZoomed)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The unzoomed picture's scroll view has nothing to scroll; let both run so the
        // scroll view never swallows the drag. (Zoomed, the dismissal does not begin.)
        g === dismissPan && other === scroll.panGestureRecognizer
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        let translation = CGSize(width: t.x, height: t.y)
        let progress = MediaDismissal.progress(translation: translation, height: view.bounds.height)
        switch g.state {
        case .began, .changed:
            let scale = MediaDismissal.scale(progress: progress)
            stage.transform = CGAffineTransform(translationX: t.x, y: t.y).scaledBy(x: scale, y: scale)
            backdrop.alpha = MediaDismissal.backgroundAlpha(progress: progress)
            topBar.alpha = chromeHidden ? 0 : max(0, 1 - progress * 3)
        case .ended:
            let v = g.velocity(in: view)
            if MediaDismissal.shouldDismiss(translation: translation, velocity: CGSize(width: v.x, height: v.y)) {
                finishDismiss(direction: t.y >= 0 ? 1 : -1, velocity: v.y)
            } else {
                springBack()
            }
        default:
            springBack()
        }
    }

    private func springBack() {
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.stage.transform = .identity
            self.backdrop.alpha = 1
            self.topBar.alpha = self.chromeHidden ? 0 : 1
        }
    }

    private func finishDismiss(direction: CGFloat, velocity: CGFloat) {
        let distance = view.bounds.height
        let duration = min(0.3, max(0.15, Double(distance / max(abs(velocity), 1))))
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
            let scale = MediaDismissal.scale(progress: 1)
            self.stage.transform = CGAffineTransform(translationX: self.stage.transform.tx, y: direction * distance).scaledBy(x: scale, y: scale)
            self.backdrop.alpha = 0
            self.topBar.alpha = 0
        } completion: { _ in
            self.close(animated: false)
        }
    }

    private func close(animated: Bool) {
        task?.cancel()
        playerController?.player?.pause()
        dismiss(animated: animated)
    }

    // MARK: Share

    private func share() {
        guard let url = prepared?.url else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = shareButton
        present(sheet, animated: true)
    }
}
#endif
