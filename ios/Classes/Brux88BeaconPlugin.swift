import Flutter
import UIKit
import CoreLocation
import CoreBluetooth

@available(iOS 13.0, *)
public class Brux88BeaconPlugin: NSObject,
                                FlutterPlugin,
                                CLLocationManagerDelegate,
                                CBCentralManagerDelegate {

  private var methodChannel: FlutterMethodChannel
  private var beaconsEventChannel: FlutterEventChannel
  private var monitoringEventChannel: FlutterEventChannel

  private let beaconsStreamHandler = BeaconsStreamHandler()
  private let monitoringStreamHandler = MonitoringStreamHandler()

  private let locationManager = CLLocationManager()
  private var centralManager: CBCentralManager!

  private var isMonitoring = false
  private var selectedBeaconUUID: UUID?
  private var selectedBeaconMajor: CLBeaconMajorValue?
  private var selectedBeaconMinor: CLBeaconMinorValue?

  // MARK: - Plugin registration

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.brux88.brux88_beacon/methods",
      binaryMessenger: registrar.messenger()
    )

    let beaconsChannel = FlutterEventChannel(
      name: "com.brux88.brux88_beacon/beacons",
      binaryMessenger: registrar.messenger()
    )

    let monitoringChannel = FlutterEventChannel(
      name: "com.brux88.brux88_beacon/monitoring",
      binaryMessenger: registrar.messenger()
    )

    let instance = Brux88BeaconPlugin(
      methodChannel: channel,
      beaconsChannel: beaconsChannel,
      monitoringChannel: monitoringChannel
    )

    registrar.addMethodCallDelegate(instance, channel: channel)

    beaconsChannel.setStreamHandler(instance.beaconsStreamHandler)
    monitoringChannel.setStreamHandler(instance.monitoringStreamHandler)
  }

  init(methodChannel: FlutterMethodChannel,
       beaconsChannel: FlutterEventChannel,
       monitoringChannel: FlutterEventChannel) {

    self.methodChannel = methodChannel
    self.beaconsEventChannel = beaconsChannel
    self.monitoringEventChannel = monitoringChannel
    super.init()
  }

  // MARK: - Method calls

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      initialize(result: result)

    case "startMonitoring":
      startMonitoring(result: result)

    case "stopMonitoring":
      stopMonitoring(result: result)

    case "setBeaconToMonitor":
      guard let args = call.arguments as? [String: Any],
            let uuid = args["uuid"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "UUID is required", details: nil))
        return
      }

      setBeaconToMonitor(
        uuid: uuid,
        major: args["major"] as? String,
        minor: args["minor"] as? String,
        enabled: args["enabled"] as? Bool ?? true,
        result: result
      )

    case "clearSelectedBeacon":
      clearSelectedBeacon(result: result)

    case "isMonitoringRunning":
      result(isMonitoring)

    case "requestPermissions":
      requestPermissions(result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Core logic

  private func initialize(result: @escaping FlutterResult) {
    locationManager.delegate = self
    centralManager = CBCentralManager(delegate: self, queue: nil)
    result(true)
  }

  private func startMonitoring(result: @escaping FlutterResult) {
    guard CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self),
          let uuid = selectedBeaconUUID else {
      result(FlutterError(code: "NO_BEACON_SELECTED", message: "No beacon selected", details: nil))
      return
    }

    let constraint: CLBeaconIdentityConstraint

    if let major = selectedBeaconMajor, let minor = selectedBeaconMinor {
      constraint = CLBeaconIdentityConstraint(uuid: uuid, major: major, minor: minor)
    } else if let major = selectedBeaconMajor {
      constraint = CLBeaconIdentityConstraint(uuid: uuid, major: major)
    } else {
      constraint = CLBeaconIdentityConstraint(uuid: uuid)
    }

    let region = CLBeaconRegion(
      beaconIdentityConstraint: constraint,
      identifier: "SelectedBeacon"
    )

    locationManager.startMonitoring(for: region)
    locationManager.startRangingBeacons(satisfying: constraint)

    isMonitoring = true
    result(true)
  }

  private func stopMonitoring(result: @escaping FlutterResult) {
    for region in locationManager.monitoredRegions {
      if let beaconRegion = region as? CLBeaconRegion {
        locationManager.stopMonitoring(for: beaconRegion)
        locationManager.stopRangingBeacons(
          satisfying: beaconRegion.beaconIdentityConstraint
        )
      }
    }

    isMonitoring = false
    result(true)
  }

  private func setBeaconToMonitor(uuid: String,
                                  major: String?,
                                  minor: String?,
                                  enabled: Bool,
                                  result: @escaping FlutterResult) {

    guard let beaconUUID = UUID(uuidString: uuid) else {
      result(FlutterError(code: "INVALID_UUID", message: "Invalid UUID format", details: nil))
      return
    }

    selectedBeaconUUID = beaconUUID
    selectedBeaconMajor = major.flatMap { UInt16($0) }
    selectedBeaconMinor = minor.flatMap { UInt16($0) }

    result(true)
  }

  private func clearSelectedBeacon(result: @escaping FlutterResult) {
    selectedBeaconUUID = nil
    selectedBeaconMajor = nil
    selectedBeaconMinor = nil
    result(true)
  }

  private func requestPermissions(result: @escaping FlutterResult) {
    locationManager.requestAlwaysAuthorization()
    result(true)
  }

  // MARK: - CLLocationManagerDelegate

  public func locationManager(_ manager: CLLocationManager,
                              didRangeBeacons beacons: [CLBeacon],
                              in region: CLBeaconRegion) {

    let data = beacons.map {
      [
        "uuid": $0.uuid.uuidString,
        "major": String(describing: $0.major),
        "minor": String(describing: $0.minor),
        "distance": $0.accuracy,
        "rssi": $0.rssi,
        "txPower": 0
      ] as [String: Any]
    }

    beaconsStreamHandler.sink?(data)
  }

  public func locationManager(_ manager: CLLocationManager,
                              didEnterRegion region: CLRegion) {
    if region is CLBeaconRegion {
      monitoringStreamHandler.sink?("INSIDE")
    }
  }

  public func locationManager(_ manager: CLLocationManager,
                              didExitRegion region: CLRegion) {
    if region is CLBeaconRegion {
      monitoringStreamHandler.sink?("OUTSIDE")
    }
  }

  // MARK: - CBCentralManagerDelegate

  public func centralManagerDidUpdateState(_ central: CBCentralManager) {}
}

// MARK: - Stream Handlers

class BeaconsStreamHandler: NSObject, FlutterStreamHandler {
  var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

class MonitoringStreamHandler: NSObject, FlutterStreamHandler {
  var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
