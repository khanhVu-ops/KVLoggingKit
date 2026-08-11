import ExampleSupport
import UIKit

@MainActor
final class LoggingViewController: UIViewController {
    private let service: ExampleLoggingService
    private let statusLabel = UILabel()
    private let latestActionView = UITextView()
    private let toggleConnectivityButton = UIButton(type: .system)

    init(service: ExampleLoggingService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "KVLoggingKit"
        view.backgroundColor = .systemBackground
        configureLayout()

        Task {
            await refresh(using: nil)
        }
    }

    private func configureLayout() {
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true

        latestActionView.font = .preferredFont(forTextStyle: .body)
        latestActionView.adjustsFontForContentSizeCategory = true
        latestActionView.isEditable = false
        latestActionView.isScrollEnabled = true
        latestActionView.backgroundColor = .secondarySystemBackground
        latestActionView.layer.cornerRadius = 12
        latestActionView.text = "Ready"
        latestActionView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)

        let generateButton = makeButton(title: "Generate sample logs", action: #selector(generateLogs))
        configure(button: toggleConnectivityButton, title: "Go offline", action: #selector(toggleConnectivity))
        let flushButton = makeButton(title: "Flush and replay queue", action: #selector(flushLogs))
        let exportButton = makeButton(title: "Export encrypted local logs", action: #selector(exportLogs))

        let stack = UIStackView(arrangedSubviews: [
            makeSectionTitle("Status"),
            statusLabel,
            makeSectionTitle("Actions"),
            generateButton,
            toggleConnectivityButton,
            flushButton,
            exportButton,
            makeSectionTitle("Latest action"),
            latestActionView
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: statusLabel)
        stack.setCustomSpacing(20, after: exportButton)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            latestActionView.heightAnchor.constraint(greaterThanOrEqualToConstant: 110)
        ])
    }

    private func makeSectionTitle(_ title: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        configure(button: button, title: title, action: action)
        return button
    }

    private func configure(button: UIButton, title: String, action: Selector) {
        if #available(iOS 15.0, *) {
            var configuration = UIButton.Configuration.filled()
            configuration.title = title
            configuration.cornerStyle = .medium
            button.configuration = configuration
        } else {
            button.setTitle(title, for: .normal)
            button.backgroundColor = view.tintColor
            button.setTitleColor(.white, for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            button.layer.cornerRadius = 10
            button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        }
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc private func generateLogs() {
        service.generateSampleLogs()
        latestActionView.text = "Generated four sample events."

        Task {
            await refresh(using: await service.flushAndSnapshot())
        }
    }

    @objc private func toggleConnectivity() {
        Task {
            let current = await service.snapshot()
            let nextState = !current.isOnline
            await service.setOnline(nextState)
            latestActionView.text = nextState ? "Mock transport is online." : "Mock transport is offline."
            await refresh(using: nil)
        }
    }

    @objc private func flushLogs() {
        Task {
            let snapshot = await service.flushAndSnapshot()
            latestActionView.text = "Flushed destinations and replayed any queued batches."
            await refresh(using: snapshot)
        }
    }

    @objc private func exportLogs() {
        Task {
            do {
                let directory = try await service.exportLocalLogs()
                latestActionView.text = "Exported encrypted logs to:\n\(directory.path)"
            } catch {
                latestActionView.text = "Export failed: \(error.localizedDescription)"
            }
            await refresh(using: nil)
        }
    }

    private func refresh(using suppliedSnapshot: ExampleSnapshot?) async {
        let snapshot: ExampleSnapshot
        if let suppliedSnapshot {
            snapshot = suppliedSnapshot
        } else {
            snapshot = await service.snapshot()
        }
        let connectivity = snapshot.isOnline ? "Online" : "Offline"
        let bootstrap = snapshot.bootstrapError.map { "\nBootstrap error: \($0)" } ?? ""

        statusLabel.text = """
        Connectivity: \(connectivity)
        Delivered batches: \(snapshot.deliveredBatchCount)
        Delivered events: \(snapshot.deliveredEventCount)
        Queued batches: \(snapshot.queuedBatchCount)
        Local files: \(snapshot.localFileCount)\(bootstrap)
        """
        updateConnectivityButton(isOnline: snapshot.isOnline)
    }

    private func updateConnectivityButton(isOnline: Bool) {
        let title = isOnline ? "Go offline" : "Go online"
        if #available(iOS 15.0, *) {
            toggleConnectivityButton.configuration?.title = title
        } else {
            toggleConnectivityButton.setTitle(title, for: .normal)
        }
    }
}
