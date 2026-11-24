import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key, required this.device});

  final BleDevice device;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  // Must match the UUIDs in the ESP32 sketch
  static const _serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const _writeUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const _notifyUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  static const _maxLogLines = 100;

  final _commandController = TextEditingController();
  final List<String> _log = [];

  BleCharacteristic? _writeChar;
  StreamSubscription<bool>? _connectionSub;
  StreamSubscription<Uint8List>? _valueSub;
  bool _isConnected = false;
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    _connectionSub = widget.device.connectionStream.listen((connected) {
      if (!mounted) return;
      setState(() => _isConnected = connected);
      if (!connected) _addLog('Disconnected');
    });
    _connect();
  }

  Future<void> _connect() async {
    setState(() => _isBusy = true);
    try {
      _addLog('Connecting...');
      await widget.device.connect();

      _addLog('Connected. Discovering services...');
      await widget.device.discoverServices();

      final notifyChar = await widget.device.getCharacteristic(
        _notifyUuid,
        service: _serviceUuid,
      );
      _writeChar = await widget.device.getCharacteristic(
        _writeUuid,
        service: _serviceUuid,
      );

      // Listen first, then subscribe, so no early values are missed
      await _valueSub?.cancel();
      _valueSub = notifyChar.onValueReceived.listen((bytes) {
        _addLog('← ${utf8.decode(bytes, allowMalformed: true)}');
      });
      await notifyChar.notifications.subscribe();

      _addLog('Ready. Listening for data.');
    } catch (e) {
      _addLog('Error: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _send(String text) async {
    final command = text.trim();
    final writeChar = _writeChar;
    if (command.isEmpty || writeChar == null) return;

    try {
      await writeChar.write(utf8.encode(command));
      _addLog('→ $command');
      _commandController.clear();
    } catch (e) {
      _addLog('Send failed: $e');
    }
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, line); // Newest first
      if (_log.length > _maxLogLines) _log.removeLast();
    });
  }

  @override
  void dispose() {
    _valueSub?.cancel();
    _connectionSub?.cancel();
    _commandController.dispose();
    widget.device.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canSend = _isConnected && _writeChar != null && !_isBusy;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name ?? 'Device'),
        actions: [
          if (_isBusy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (!_isConnected)
            IconButton(
              tooltip: 'Reconnect',
              icon: const Icon(Icons.refresh),
              onPressed: _connect,
            ),
        ],
      ),
      body: Column(
        children: [
          ListTile(
            leading: Icon(
              _isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              color: _isConnected ? Colors.teal : Colors.grey,
            ),
            title: Text(_isConnected ? 'Connected' : 'Not connected'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _commandController,
                    enabled: canSend,
                    decoration: const InputDecoration(
                      labelText: 'Command',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: _send,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send',
                  icon: const Icon(Icons.send),
                  onPressed:
                  canSend ? () => _send(_commandController.text) : null,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                OutlinedButton(
                  onPressed: canSend ? () => _send('START') : null,
                  child: const Text('START'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: canSend ? () => _send('STOP') : null,
                  child: const Text('STOP'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _log.length,
              itemBuilder: (context, index) => Text(
                _log[index],
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}