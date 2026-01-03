import Flutter
import UIKit
import CoreLocation
import CoreBluetooth

@available(iOS 13.0, *)
public class Brux88BeaconPlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate, CBCentralManagerDelegate {
  private var methodChannel: FlutterMethodChannel
  private var beaconsEventChannel: FlutterEventChannel
  private var monitoringEventChannel: FlutterEventChannel
  
  private var beaconsSink: FlutterEventSink?
  private var monitoringSink: FlutterEventSink?
  
  private let locationManager = CLLocationManager()
  private var centralManager: CBCentralManager!
  
  private var isMonitoring = false
  private var selectedBeaconUUID: UUID?
  private var selectedBeaconMajor: CLBeaconMajorValue?
  private var selectedBeaconMinor: CLBeaconMinorValue?
  
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.brux88.flutter_plinn_beacon/methods", binaryMessenger: registrar.messenger())
    let beaconsChannel = FlutterEventChannel(name: "com.brux88.flutter_plinn_beacon/beacons", binaryMessenger: registrar.messenger())
    let monitoringChannel = FlutterEventChannel(name: "com.brux88.flutter_plinn_beacon/monitoring", binaryMessenger: registrar.messenger())
    
    let instance = Brux88BeaconPlugin(methodChannel: channel, beaconsChannel: beaconsChannel, monitoringChannel: monitoringChannel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    
    beaconsChannel.setStreamHandler(BeaconsStreamHandler(sink: { [weak instance] sink in
      instance?.beaconsSink = sink
    }, onCancel: { [weak instance] in
      instance?.beaconsSink = nil
    }))

    monitoringChannel.setStreamHandler(MonitoringStreamHandler(sink: { [weak instance] sink in
      instance?.monitoringSink = sink
    }, onCancel: { [weak instance] in
      instance?.monitoringSink = nil
    }))
  }
  
  init(methodChannel: FlutterMethodChannel, beaconsChannel: FlutterEventChannel, monitoringChannel: FlutterEventChannel) {
    self.methodChannel = methodChannel
    self.beaconsEventChannel = beaconsChannel
    self.monitoringEventChannel = monitoringChannel
    super.init()
  }
  
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
      
      let major = args["major"] as? String
      let minor = args["minor"] as? String
      let enabled = args["enabled"] as? Bool ?? true
      
      setBeaconToMonitor(uuid: uuid, major: major, minor: minor, enabled: enabled, result: result)
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
  
  private func initialize(result: @escaping FlutterResult) {
    locationManager.delegate = self
    centralManager = CBCentralManager(delegate: self, queue: nil)
    result(true)
  }
  
  private func startMonitoring(result: @escaping FlutterResult) {
    guard CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) else {
      result(FlutterError(code: "MONITORING_NOT_AVAILABLE", message: "Beacon monitoring not available", details: nil))
      return
    }
    
    // Start monitoring for beacons
    if let selectedUUID = selectedBeaconUUID {
      // Start monitoring for specific beacon
      var beaconConstraints: [NSNumber]? = nil
      if let major = selectedBeaconMajor {
        if let minor = selectedBeaconMinor {
          beaconConstraints = [NSNumber(value: major), NSNumber(value: minor)]
        } else {
          beaconConstraints = [NSNumber(value: major)]
        }
      }
      
      let constraint = CLBeaconIdentityConstraint(uuid: selectedUUID, major: selectedBeaconMajor, minor: selectedBeaconMinor)
      let beaconRegion = CLBeaconRegion(beaconIdentityConstraint: constraint, identifier: "SelectedBeacon")
      locationManager.startMonitoring(for: beaconRegion)
      locationManager.startRangingBeacons(satisfying: constraint)
    } else {
      // Example: monitoring for all iBeacons with a wildcard UUID
      // In a real implementation, you would likely use specific UUIDs
      // This is just a placeholder
      result(FlutterError(code: "NO_BEACON_SELECTED", message: "No beacon selected", details: nil))
      return
    }
    
    isMonitoring = true
    result(true)
  }
  
  private func stopMonitoring(result: @escaping FlutterResult) {
    locationManager.monitoredRegions.forEach { region in
      if let beaconRegion = region as? CLBeaconRegion {
        locationManager.stopMonitoring(for: beaconRegion)
        locationManager.stopRangingBeacons(satisfying: beaconRegion.beaconIdentityConstraint)
      }
    }
    
    isMonitoring = false
    result(true)
  }
  
  private func setBeaconToMonitor(uuid: String, major: String?, minor: String?, enabled: Bool, result: @escaping FlutterResult) {
    guard let beaconUUID = UUID(uuidString: uuid) else {
      result(FlutterError(code: "INVALID_UUID", message: "Invalid UUID format", details: nil))
      return
    }
    
    selectedBeaconUUID = beaconUUID
    
    if let majorStr = major, let majorVal = UInt16(majorStr) {
      selectedBeaconMajor = majorVal
    } else {
      selectedBeaconMajor = nil
    }
    
    if let minorStr = minor, let minorVal = UInt16(minorStr) {
      selectedBeaconMinor = minorVal
    } else {
      selectedBeaconMinor = nil
    }
    
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
  
  public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    // Handle authorization changes
  }
  
  public func locationManager(_ manager: CLLocationManager, didRangeBeacons beacons: [CLBeacon], in region: CLBeaconRegion) {
    guard let sink = beaconsSink, !beacons.isEmpty else { return }
    
    let beaconMaps = beacons.map { beacon -> [String: Any] in
      return [
        "uuid": beacon.uuid.uuidString,
        "major": String(beacon.major),
        "minor": String(beacon.minor),
        "distance": beacon.accuracy,
        "rssi": beacon.rssi,
        "txPower": 0 // iOS doesn't expose txPower
      ]
    }
    
    sink(beaconMaps)
  }
  
  public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    if region is CLBeaconRegion {
      monitoringSink?("INSIDE")
    }
  }
  
  public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    if region is CLBeaconRegion {
      monitoringSink?("OUTSIDE")
    }
  }
  
  // MARK: - CBCentralManagerDelegate
  
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    // Handle Bluetooth state changes
  }

  // Implementazione dei metodi avanzati
  private func startMonitoringForRegion(args: [String: Any], result: @escaping FlutterResult) {
    guard let identifier = args["identifier"] as? String,
          let uuid = args["uuid"] as? String,
          let beaconUUID = UUID(uuidString: uuid) else {
      result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid region arguments", details: nil))
      return
    }
    
    var majorValue: CLBeaconMajorValue?
    var minorValue: CLBeaconMinorValue?
    
    if let major = args["major"] as? UInt16 {
      majorValue = major
    } else if let majorStr = args["major"] as? String, let major = UInt16(majorStr) {
      majorValue = major
    }

    if let minor = args["minor"] as? UInt16 {
      minorValue = minor
    } else if let minorStr = args["minor"] as? String, let minor = UInt16(minorStr) {
      minorValue = minor
    }
    
    let constraint = CLBeaconIdentityConstraint(uuid: beaconUUID, major: majorValue, minor: minorValue)
    let region = CLBeaconRegion(beaconIdentityConstraint: constraint, identifier: identifier)
    
    // Configurazione aggiuntiva
    if let notifyOnDisplay = args["notifyEntryStateOnDisplay"] as? Bool, notifyOnDisplay {
      region.notifyEntryStateOnDisplay = true
    }
    
    locationManager.startMonitoring(for: region)
    locationManager.startRangingBeacons(satisfying: constraint)
    
    result(true)
  }

  private func stopMonitoringForRegion(args: [String: Any], result: @escaping FlutterResult) {
    guard let identifier = args["identifier"] as? String else {
      result(FlutterError(code: "INVALID_ARGUMENTS", message: "Region identifier required", details: nil))
      return
    }
    
    for region in locationManager.monitoredRegions {
      if region.identifier == identifier {
        locationManager.stopMonitoring(for: region)
        if let beaconRegion = region as? CLBeaconRegion {
          locationManager.stopRangingBeacons(satisfying: beaconRegion.beaconIdentityConstraint)
        }
        result(true)
        return
      }
    }
    
    result(false)
  }

  private func getMonitoredRegions(result: @escaping FlutterResult) {
    let regions = locationManager.monitoredRegions.compactMap { region -> [String: Any]? in
      guard let beaconRegion = region as? CLBeaconRegion else {
        return nil
      }
      
      var regionMap: [String: Any] = [
        "identifier": beaconRegion.identifier,
        "uuid": beaconRegion.beaconIdentityConstraint.uuid.uuidString,
        "notifyEntryStateOnDisplay": beaconRegion.notifyEntryStateOnDisplay
      ]
      
      if let major = beaconRegion.beaconIdentityConstraint.major {
        regionMap["major"] = "\(major)"
      }
      
      if let minor = beaconRegion.beaconIdentityConstraint.minor {
        regionMap["minor"] = "\(minor)"
      }
      
      return regionMap
    }
    
    result(regions)
  }


}

// MARK: - Stream Handlers

class BeaconsStreamHandler: NSObject, FlutterStreamHandler {
  private let onListen: (FlutterEventSink) -> Void
  private let onCancel: () -> Void
  
  init(sink: @escaping (FlutterEventSink) -> Void, onCancel: @escaping () -> Void) {
    self.onListen = sink
    self.onCancel = onCancel
    super.init()
  }
  
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onListen(events)
    return nil
  }
  
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onCancel()
    return nil
  }
}

class MonitoringStreamHandler: NSObject, FlutterStreamHandler {
  private let onListen: (FlutterEventSink) -> Void
  private let onCancel: () -> Void
  
  init(sink: @escaping (FlutterEventSink) -> Void, onCancel: @escaping () -> Void) {
    self.onListen = sink
    self.onCancel = onCancel
    super.init()
  }
  
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onListen(events)
    return nil
  }
  
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onCancel()
    return nil
  }
}