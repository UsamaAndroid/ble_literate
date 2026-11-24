import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
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
  static const _getDeviceId = 0xC0;
  static const _getBattery = 0xC2;

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
        if (listEquals(bytes, _buildRequest(_getDeviceId))) {
          _addLog('← C0 echo: ${_hex(bytes)}');
        } else if (bytes.length >= 8 &&
            bytes[0] == 0x50 &&
            bytes[4] == 0x91 &&
            (bytes[7] == _getDeviceId || bytes[7] == _getBattery)) {
          final reply = _decodeSimulatedReply(bytes);
          _addLog(reply ?? 'Invalid simulator reply: ${_hex(bytes)}');
        } else {
          _addLog('← ${utf8.decode(bytes, allowMalformed: true)}');
        }
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

  // The request length bytes follow the vendor's C0 example.
  Uint8List _buildRequest(int command) {
    final frame = Uint8List.fromList([
      0x50,
      0x80,
      0x01,
      0x04,
      0x81,
      0x00,
      0x01,
      command,
      0x00,
    ]);
    frame.last = _checksum(frame);
    return frame;
  }

  Future<void> _sendReadCommand(int command) async {
    final writeChar = _writeChar;
    if (writeChar == null) return;

    final frame = _buildRequest(command);
    final label = _hex([command]);
    try {
      await writeChar.write(frame);
      _addLog('→ $label: ${_hex(frame)}');
    } catch (e) {
      _addLog('$label send failed: $e');
    }
  }

  // Matches the provisional single-packet reply in SkinCareSim.ino.
  String? _decodeSimulatedReply(Uint8List bytes) {
    const payloadOffset = 8;
    final checksumOffset = bytes.length - 1;
    if (checksumOffset <= payloadOffset ||
        bytes[1] != 0x80 ||
        bytes[2] != 0x01 ||
        bytes[3] != bytes.length - 5 ||
        bytes[5] != 0x00 ||
        bytes[6] != checksumOffset - payloadOffset + 1) {
      return null;
    }

    if (_checksum(bytes) != bytes[checksumOffset]) return null;

    final payload = bytes.sublist(payloadOffset, checksumOffset);
    if (bytes[7] == _getBattery) {
      if (payload.length != 1 || payload.single > 100) return null;
      return 'Simulated battery: ${payload.single}%';
    }

    if (payload.any((byte) => byte < 0x20 || byte > 0x7E)) return null;
    return 'Simulated device ID: ${ascii.decode(payload)}';
  }

  int _checksum(Uint8List bytes) {
    var checksum = 0;
    for (var i = 1; i < bytes.length - 1; i++) {
      checksum ^= bytes[i];
    }
    return checksum;
  }

  String _hex(List<int> bytes) => bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

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
              _isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
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
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: canSend ? () => _send('START') : null,
                  child: const Text('START'),
                ),
                OutlinedButton(
                  onPressed: canSend ? () => _send('STOP') : null,
                  child: const Text('STOP'),
                ),
                OutlinedButton(
                  onPressed:
                      canSend ? () => _sendReadCommand(_getDeviceId) : null,
                  child: const Text('Send C0'),
                ),
                OutlinedButton(
                  onPressed:
                      canSend ? () => _sendReadCommand(_getBattery) : null,
                  child: const Text('Get Battery'),
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
