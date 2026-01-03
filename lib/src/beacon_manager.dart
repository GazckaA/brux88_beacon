// lib/src/beacon_manager.dart
import 'dart:async';
import 'dart:io';
import 'package:brux88_beacon/brux88_beacon.dart';
import 'package:flutter/services.dart';
import 'models/beacon.dart';
import 'models/beacon_region.dart';
import 'models/monitoring_state.dart';
import 'models/notification_settings.dart';
import 'models/scan_settings.dart';

class BeaconManager {
  bool get _isIOS => Platform.isIOS;
  bool get _isAndroid => Platform.isAndroid;

  static const MethodChannel _methodChannel =
      MethodChannel('com.brux88.brux88_beacon/methods');

  static const EventChannel _beaconsEventChannel =
      EventChannel('com.brux88.brux88_beacon/beacons');

  static const EventChannel _monitoringEventChannel =
      EventChannel('com.brux88.brux88_beacon/monitoring');

  // Singleton pattern
  static final BeaconManager _instance = BeaconManager._internal();
  factory BeaconManager() => _instance;
  BeaconManager._internal();

  // Stream controllers
  final _beaconsController = StreamController<List<Beacon>>.broadcast();
  final _monitoringController = StreamController<MonitoringState>.broadcast();

  Stream<List<Beacon>> get beacons => _beaconsController.stream;
  Stream<MonitoringState> get monitoringState => _monitoringController.stream;

  bool _isInitialized = false;

  /// Initialize the beacon manager
  Future<bool> initialize() async {
    try {
      // Se è già inizializzato, non facciamo nulla
      if (_isInitialized) return true;

      // Imposta il flag di monitoraggio a false nelle preferenze
      // senza cercare di fermare il monitoraggio attivo
      if (_isAndroid) {
        try {
          // Imposta direttamente il flag di monitoraggio a false
          await _methodChannel.invokeMethod('setMonitoringEnabled', false);
          print('Set monitoring flag to false before initialization');
        } catch (e) {
          print('Error setting monitoring flag: $e');
          // Continua comunque con l'inizializzazione
        }
      }

      // Ora proviamo a inizializzare
      final result =
          await _methodChannel.invokeMethod<bool>('initialize') ?? false;

      if (result) {
        _setupEventChannels();
        _isInitialized = true;
      }

      return result;
    } catch (e) {
      print('Error initializing beacon manager: $e');
      return false;
    }
  }

  void _setupEventChannels() {
    _beaconsEventChannel.receiveBroadcastStream().listen((dynamic event) {
      // Verifica che event sia effettivamente una List
      if (event is List) {
        final beaconsList = event
            .map((e) => Beacon.fromMap(e as Map<dynamic, dynamic>))
            .toList();
        _beaconsController.add(beaconsList);
      } else if (event is String) {
        // Se è una stringa (errore o messaggio di debug), registralo
        print('Received string message from beacon channel: $event');
        // Eventualmente, puoi anche inviare una lista vuota
        _beaconsController.add([]);
      } else if (event is Map) {
        // Se è un singolo beacon (mappa invece di lista di mappe)
        try {
          final beacon = Beacon.fromMap(event);
          _beaconsController.add([beacon]);
        } catch (e) {
          print('Error parsing single beacon: $e');
          _beaconsController.add([]);
        }
      } else {
        // In caso di altri tipi, invia lista vuota
        print(
            'Unexpected event type from beacon channel: ${event.runtimeType}');
        _beaconsController.add([]);
      }
    }, onError: (dynamic error) {
      print('Error from beacons stream: $error');
      _beaconsController.add([]);
    });

    _monitoringEventChannel.receiveBroadcastStream().listen((dynamic event) {
      // Anche qui, verifica il tipo
      if (event is String) {
        final state = _parseMonitoringState(event);
        _monitoringController.add(state);
      } else {
        print('Unexpected monitoring event type: ${event.runtimeType}');
      }
    }, onError: (dynamic error) {
      print('Error from monitoring stream: $error');
    });
  }

  MonitoringState _parseMonitoringState(String state) {
    switch (state) {
      case 'INSIDE':
        return MonitoringState.inside;
      case 'OUTSIDE':
        return MonitoringState.outside;
      default:
        return MonitoringState.unknown;
    }
  }

  Future<bool> enableAllAutoRestart() async {
    if (_isIOS) return true;
    try {
      final autoRestart = await setAutoRestartEnabled(true);
      final alarms = await setupRecurringAlarm();

      print('Auto-restart enabled: $autoRestart');
      print('Alarms setup: $alarms');

      return autoRestart && alarms;
    } catch (e) {
      print('Error enabling auto-restart: $e');
      return false;
    }
  }

  Future<bool> disableAllAutoRestart() async {
    if (_isIOS) return true;
    final watchdog = await setWatchdogEnabled(false);
    final autoRestart = await setAutoRestartEnabled(false);
    final alarms = await cancelRecurringAlarm();

    return watchdog && autoRestart && alarms;
  }

  Future<bool> setWatchdogEnabled(bool enabled) async {
    if (_isIOS) return false;
    return await _methodChannel.invokeMethod<bool>(
            'setWatchdogEnabled', enabled) ??
        false;
  }

  Future<bool> isAutoRestartEnabled() async {
    return await _methodChannel.invokeMethod<bool>('isAutoRestartEnabled') ??
        false;
  }

  /// Enable/disable automatic service restart mechanisms
  Future<bool> setAutoRestartEnabled(bool enabled) async {
    if (_isIOS) return false;
    return await _methodChannel.invokeMethod<bool>(
            'setAutoRestartEnabled', enabled) ??
        false;
  }

  /// Setup a recurring alarm to restart the beacon monitoring service periodically
  Future<bool> setupRecurringAlarm() async {
    if (_isIOS) return false;
    return await _methodChannel.invokeMethod<bool>('setupRecurringAlarm') ??
        false;
  }

  /// Cancel the recurring alarm
  Future<bool> cancelRecurringAlarm() async {
    if (_isIOS) return false;
    return await _methodChannel.invokeMethod<bool>('cancelRecurringAlarm') ??
        false;
  }

  // ===== MONITORAGGIO FOREGROUND SEPARATO =====

  /// Start only foreground monitoring (ranging) without background service
  Future<bool> startForegroundMonitoringOnly() async {
    if (!_isInitialized) await initialize();
    return await _methodChannel
            .invokeMethod<bool>('startForegroundMonitoringOnly') ??
        false;
  }

  /// Stop only foreground monitoring without affecting background service
  Future<bool> stopForegroundMonitoringOnly() async {
    return await _methodChannel
            .invokeMethod<bool>('stopForegroundMonitoringOnly') ??
        false;
  }

  /// Check if foreground monitoring is running
  Future<bool> isForegroundMonitoringRunning() async {
    return await _methodChannel
            .invokeMethod<bool>('isForegroundMonitoringRunning') ??
        false;
  }

  // ===== CONTROLLO COMPLETO =====

  /// Start COMPLETE monitoring (both foreground ranging and background service)
  /// This is the same as the original startMonitoring() but now it's clear what it does
  Future<bool> startCompleteMonitoring() async {
    if (!_isInitialized) await initialize();
    return await _methodChannel.invokeMethod<bool>('startMonitoring') ?? false;
  }

  /// Stop COMPLETE monitoring (both foreground ranging and background service)
  /// This is the same as the original stopMonitoring() but now it's clear what it does
  Future<bool> stopCompleteMonitoring() async {
    return await _methodChannel.invokeMethod<bool>('stopMonitoring') ?? false;
  }

  // ===== METODI LEGACY (mantenuti per compatibilità) =====

  /// Start monitoring for beacons
  /// NOTE: This starts BOTH foreground and background monitoring
  /// Use startForegroundMonitoringOnly() or startBackgroundService() for specific control
  Future<bool> startMonitoring() async {
    if (!_isInitialized) await initialize();
    return await _methodChannel.invokeMethod<bool>('startMonitoring') ?? false;
  }

  /// Stop monitoring for beacons
  /// NOTE: This stops BOTH foreground and background monitoring
  /// Use stopForegroundMonitoringOnly() or stopBackgroundService() for specific control
  Future<bool> stopMonitoring() async {
    return await _methodChannel.invokeMethod<bool>('stopMonitoring') ?? false;
  }

  /// Check if beacon monitoring is running
  /// NOTE: This returns true if EITHER foreground OR background is running
  /// Use isForegroundMonitoringRunning() or isBackgroundServiceRunning() for specific status
  Future<bool> isMonitoringRunning() async {
    final foregroundRunning = await isForegroundMonitoringRunning();
    final backgroundRunning = await isBackgroundServiceRunning();
    return foregroundRunning || backgroundRunning;
  }

  // ===== NUOVE FUNZIONALITÀ PER CONTROLLO SERVIZIO BACKGROUND =====

  /// Start only the background service without foreground monitoring
  Future<bool> startBackgroundService() async {
    if (_isIOS) return false;
    if (!_isInitialized) await initialize();
    return await _methodChannel.invokeMethod<bool>('startBackgroundService') ??
        false;
  }

  /// Stop only the background service
  Future<bool> stopBackgroundService() async {
    if (_isIOS) return false;
    return await _methodChannel.invokeMethod<bool>('stopBackgroundService') ??
        false;
  }

  /// Restart the background service
  Future<bool> restartBackgroundService() async {
    if (_isIOS) return false;
    try {
      await stopBackgroundService();
      // Piccola pausa per assicurarsi che il servizio sia completamente fermato
      await Future.delayed(Duration(milliseconds: 500));
      return await startBackgroundService();
    } catch (e) {
      print('Error restarting background service: $e');
      return false;
    }
  }

  /// Check if the background service is running
  Future<bool> isBackgroundServiceRunning() async {
    if (_isIOS) return false;
    return await _methodChannel
            .invokeMethod<bool>('isBackgroundServiceRunning') ??
        false;
  }

  /// Enable/disable background service auto-start
  Future<bool> setBackgroundServiceEnabled(bool enabled) async {
    if (_isIOS) return false;
    return await _methodChannel.invokeMethod<bool>(
            'setBackgroundServiceEnabled', enabled) ??
        false;
  }

  /// Check if background service auto-start is enabled
  Future<bool> isBackgroundServiceEnabled() async {
    if (_isIOS) return false;
    return await _methodChannel
            .invokeMethod<bool>('isBackgroundServiceEnabled') ??
        false;
  }

  // ===== FINE NUOVE FUNZIONALITÀ =====

  /// Start monitoring for a specific region
  Future<bool> startMonitoringForRegion(BeaconRegion region) async {
    if (!_isInitialized) await initialize();
    return await _methodChannel.invokeMethod<bool>(
            'startMonitoringForRegion', region.toMap()) ??
        false;
  }

  /// Stop monitoring for a specific region
  Future<bool> stopMonitoringForRegion(String identifier) async {
    return await _methodChannel.invokeMethod<bool>(
            'stopMonitoringForRegion', {'identifier': identifier}) ??
        false;
  }

  /// Ottiene i log dal repository
  Future<List<String>> getLogs() async {
    try {
      final List<dynamic> logs =
          await _methodChannel.invokeMethod('getLogs') ?? [];
      return logs.map((log) => log.toString()).toList();
    } catch (e) {
      print('Errore nel recupero dei log: $e');
      return [];
    }
  }

  /// Abilita la modalità debug per più log
  Future<bool> enableDebugMode() async {
    return await _methodChannel.invokeMethod<bool>('enableDebugMode') ?? false;
  }

  /// Get all currently monitored regions
  Future<List<BeaconRegion>> getMonitoredRegions() async {
    final regionsMap =
        await _methodChannel.invokeMethod<List<dynamic>>('getMonitoredRegions');
    if (regionsMap == null) return [];

    return regionsMap.map((regionMap) {
      final map = Map<String, dynamic>.from(regionMap as Map);
      return BeaconRegion(
        identifier: map['identifier'] as String,
        uuid: map['uuid'] as String,
        major: map['major'] as String?,
        minor: map['minor'] as String?,
        notifyEntryStateOnDisplay:
            map['notifyEntryStateOnDisplay'] as bool? ?? false,
      );
    }).toList();
  }

  /// Verifica se il BeaconManager è inizializzato
  Future<bool> isInitialized() async {
    try {
      return await _methodChannel.invokeMethod<bool>('isInitialized') ?? false;
    } catch (e) {
      print('Errore nella verifica dell\'inizializzazione: $e');
      return false;
    }
  }

  /// Richiede il permesso per impostare allarmi esatti (necessario per Android 12+)
  Future<bool> requestExactAlarmPermission() async {
    if (_isAndroid) {
      return await _methodChannel
              .invokeMethod<bool>('requestExactAlarmPermission') ??
          false;
    }
    return true; // Su iOS non è necessario
  }

  /// Set a specific beacon to monitor
  Future<bool> setBeaconToMonitor({
    required String uuid,
    String? major,
    String? minor,
    String? name,
    bool enabled = true,
  }) async {
    return await _methodChannel.invokeMethod<bool>('setBeaconToMonitor', {
          'uuid': uuid,
          'major': major,
          'minor': minor,
          'name': name,
          'enabled': enabled,
        }) ??
        false;
  }

  /// Clear selected beacon
  Future<bool> clearSelectedBeacon() async {
    return await _methodChannel.invokeMethod<bool>('clearSelectedBeacon') ??
        false;
  }

  /// Set scan settings
  Future<bool> setScanSettings(ScanSettings settings) async {
    return await _methodChannel.invokeMethod<bool>(
            'setScanSettings', settings.toMap()) ??
        false;
  }

  /// Get current scan settings
  Future<ScanSettings> getScanSettings() async {
    final settingsMap = await _methodChannel
        .invokeMethod<Map<dynamic, dynamic>>('getScanSettings');
    if (settingsMap == null) {
      return ScanSettings();
    }

    final map = Map<String, dynamic>.from(settingsMap);
    return ScanSettings(
      backgroundScanPeriod: map['backgroundScanPeriod'] as int? ?? 1100,
      backgroundBetweenScanPeriod:
          map['backgroundBetweenScanPeriod'] as int? ?? 5000,
      foregroundScanPeriod: map['foregroundScanPeriod'] as int? ?? 1100,
      foregroundBetweenScanPeriod:
          map['foregroundBetweenScanPeriod'] as int? ?? 0,
      maxTrackingAge: map['maxTrackingAge'] as int? ?? 5000,
    );
  }

  /// Set notification settings
  Future<bool> setNotificationSettings(NotificationSettings settings) async {
    return await _methodChannel.invokeMethod<bool>(
            'setNotificationSettings', settings.toMap()) ??
        false;
  }

  /// Non influisce sulle notifiche del servizio in foreground
  Future<bool> setShowDetectionNotifications(bool show) async {
    return await _methodChannel.invokeMethod<bool>(
            'setShowDetectionNotifications', show) ??
        false;
  }

  Future<bool> setAutoStartEnabled(bool enabled) async {
    return await _methodChannel.invokeMethod<bool>(
            'setAutoStartEnabled', enabled) ??
        false;
  }

  /// Request necessary permissions
  Future<bool> requestPermissions() async {
    try {
      // Il metodo requestPermissions su Android restituisce una Map dei permessi
      // invece di un semplice bool, quindi gestiamo entrambi i casi
      final result = await _methodChannel.invokeMethod('requestPermissions');

      if (result is bool) {
        return result;
      } else if (result is Map) {
        // Se restituisce una mappa, controlliamo che tutti i permessi essenziali siano concessi
        final permissionsMap = Map<String, bool>.from(result);

        // Permessi essenziali che devono essere tutti true
        final essentialPermissions = ['location'];

        // Su Android 12+, aggiungi i permessi Bluetooth
        if (Platform.isAndroid) {
          essentialPermissions.addAll(['bluetoothScan', 'bluetoothConnect']);
        }

        // Controlla se tutti i permessi essenziali sono concessi
        for (String permission in essentialPermissions) {
          if (permissionsMap[permission] != true) {
            print('Permission $permission not granted');
            return false;
          }
        }

        return true;
      } else {
        print(
            'Unexpected result type from requestPermissions: ${result.runtimeType}');
        return false;
      }
    } catch (e) {
      print('Error requesting permissions: $e');
      return false;
    }
  }

  /// Request permissions and get detailed status
  Future<Map<String, dynamic>> getDetailedPermissions() async {
    try {
      final result = await _methodChannel
          .invokeMethod<Map<dynamic, dynamic>>('getDetailedPermissions');
      if (result != null) {
        return Map<String, dynamic>.from(result);
      } else {
        return {};
      }
    } catch (e) {
      print('Error getting detailed permissions: $e');
      return {};
    }
  }

  /// Request permissions and get detailed status (legacy method)
  Future<Map<String, bool>> requestPermissionsDetailed() async {
    try {
      final result = await _methodChannel.invokeMethod('requestPermissions');

      if (result is Map) {
        return Map<String, bool>.from(result);
      } else if (result is bool) {
        // Se restituisce un bool, assumiamo che tutti i permessi base siano nel suo stato
        return {
          'location': result,
          'bluetoothScan': result,
          'bluetoothConnect': result,
          'notifications': result,
          'backgroundLocation': result,
        };
      } else {
        return {};
      }
    } catch (e) {
      print('Error requesting detailed permissions: $e');
      return {};
    }
  }

  /// Verifica se il Bluetooth è abilitato
  Future<bool> isBluetoothEnabled() async {
    return await _methodChannel.invokeMethod<bool>('isBluetoothEnabled') ??
        false;
  }

  /// Verifica se la localizzazione è abilitata
  Future<bool> isLocationEnabled() async {
    return await _methodChannel.invokeMethod<bool>('isLocationEnabled') ??
        false;
  }

  /// Controllo dei permessi
  Future<Map<String, bool>> checkPermissions() async {
    final result = await _methodChannel
        .invokeMethod<Map<dynamic, dynamic>>('checkPermissions');
    if (result == null) return {};

    return Map<String, bool>.from(
        result.map((key, value) => MapEntry(key.toString(), value as bool)));
  }

  /// Controllo delle ottimizzazioni batteria
  Future<bool> isBatteryOptimizationIgnored() async {
    return await _methodChannel
            .invokeMethod<bool>('isBatteryOptimizationIgnored') ??
        false;
  }

  /// Richiesta di ignorare le ottimizzazioni batteria
  Future<bool> requestIgnoreBatteryOptimization() async {
    return await _methodChannel
            .invokeMethod<bool>('requestIgnoreBatteryOptimization') ??
        false;
  }

  /// Dispose streams
  void dispose() {
    _beaconsController.close();
    _monitoringController.close();
  }
}
