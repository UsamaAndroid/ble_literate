import 'dart:async';

import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

void main() {
  runApp(const BleTestApp());
}

class BleTestApp extends StatelessWidget {
  const BleTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Test',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const ScanScreen(),
    );
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  static const _targetName = 'SkinCare-Sim';

  // Keyed by deviceId so the same device isn't added twice
  final Map<String, BleDevice> _devices = {};
  StreamSubscription<BleDevice>? _scanSub;
  Timer? _scanTimer;
  bool _isScanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scanSub = UniversalBle.scanStream.listen((device) {
      // Skip unnamed devices to keep the list readable
      if ((device.name ?? '').isEmpty) return;
      setState(() => _devices[device.deviceId] = device);
    });
  }

  Future<void> _startScan() async {
    setState(() {
      _devices.clear();
      _error = null;
    });

    try {
      final state = await UniversalBle.getBluetoothAvailabilityState();
      if (state != AvailabilityState.poweredOn) {
        setState(() => _error = 'Please turn on Bluetooth');
        return;
      }

      // await UniversalBle.startScan(
      //   platformConfig: PlatformConfig(
      //     // ESP32 uses legacy (BLE 4.x) advertising
      //     android: AndroidOptions(legacy: true),
      //   ),
      // );
      await UniversalBle.startScan();
      setState(() => _isScanning = true);

      // Stop automatically after 10 seconds to save battery
      _scanTimer = Timer(const Duration(seconds: 10), _stopScan);
    } catch (e) {
      setState(() => _error = 'Scan failed: $e');
    }
  }

  Future<void> _stopScan() async {
    _scanTimer?.cancel();
    await UniversalBle.stopScan();
    if (mounted) setState(() => _isScanning = false);
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _scanSub?.cancel();
    UniversalBle.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices.values.toList();

    return Scaffold(
      appBar: AppBar(title: const Text('BLE Scanner')),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (_isScanning) const LinearProgressIndicator(),
          Expanded(
            child: devices.isEmpty
                ? const Center(child: Text('Tap Scan to find devices'))
                : ListView.builder(
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index];
                final isTarget = device.name == _targetName;
                return ListTile(
                  leading: Icon(
                    Icons.bluetooth,
                    color: isTarget ? Colors.teal : null,
                  ),
                  title: Text(
                    device.name ?? 'Unknown',
                    style: TextStyle(
                      fontWeight:
                      isTarget ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(device.deviceId),
                  trailing: Text('${device.rssi} dBm'),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? _stopScan : _startScan,
        icon: Icon(_isScanning ? Icons.stop : Icons.search),
        label: Text(_isScanning ? 'Stop' : 'Scan'),
      ),
    );
  }
}