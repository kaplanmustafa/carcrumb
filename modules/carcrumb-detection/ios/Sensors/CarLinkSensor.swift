import AVFoundation
import Foundation

/// Car link from the audio route: CarPlay / car head unit shows up as `.carAudio`.
///
/// Threading: `routeChangeNotification` is posted on an AVAudioSession-internal thread; we
/// observe it with `queue: nil` (delivered on that posting thread) and only read
/// `currentRoute` and enqueue to the engine. `start()` is called on main at launch.
///
/// We never activate or configure the audio session (no `setActive`, no category change):
/// reading `currentRoute` and receiving route-change notifications does not need it, and
/// touching the session would interrupt the user's music.
final class CarLinkSensor: @unchecked Sendable {
  /// Sent only when the connected value changes (and once at start).
  var onEvent: (@Sendable (DetectionEvent) -> Void)?

  private var observer: NSObjectProtocol?
  private let lock = NSLock()
  private var lastConnected: Bool?
  private(set) var lastSnapshot: AudioRouteSnapshot?

  func start() {
    lock.lock()
    let alreadyStarted = observer != nil
    if !alreadyStarted {
      observer = NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
      ) { [weak self] _ in
        self?.evaluate()
      }
    }
    lock.unlock()
    if !alreadyStarted { evaluate() }
  }

  func stop() {
    lock.lock(); defer { lock.unlock() }
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }

  var isConnected: Bool {
    lock.lock(); defer { lock.unlock() }
    return lastConnected ?? false
  }

  private func evaluate() {
    let snapshot = AudioRouteSnapshot(route: AVAudioSession.sharedInstance().currentRoute)
    lock.lock()
    lastSnapshot = snapshot
    let changed = lastConnected != snapshot.carAudio
    lastConnected = snapshot.carAudio
    lock.unlock()
    if changed { onEvent?(.carLink(connected: snapshot.carAudio)) }
  }
}

/// What the route tells us. Only `carAudio` feeds the reducer today.
///
/// `bluetoothPorts` is collected for the later "Bu senin araban mı?" suggestion
/// (docs/DECISIONS.md, "Araç sinyali"): after 2–3 trips the common Bluetooth port UID can be
/// proposed and, once confirmed, counted as a car link. Not persisted, logged or sent to JS yet.
/// When it starts feeding the reducer it must also go into the trace format.
struct AudioRouteSnapshot: Equatable {
  struct BluetoothPort: Equatable {
    var uid: String
    var name: String
    var type: String
  }

  var carAudio: Bool
  var bluetoothPorts: [BluetoothPort]

  init(route: AVAudioSessionRouteDescription) {
    let outputs = route.outputs
    carAudio = outputs.contains { $0.portType == .carAudio }
    let btTypes: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
    bluetoothPorts = (outputs + route.inputs)
      .filter { btTypes.contains($0.portType) }
      .map { BluetoothPort(uid: $0.uid, name: $0.portName, type: $0.portType.rawValue) }
  }
}
