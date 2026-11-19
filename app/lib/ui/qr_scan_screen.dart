import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/pairing_payload.dart';

/// Full-screen camera scanner for the QR code shown by the PC agent.
///
/// Pops with a validated [PairingPayload] on the first good scan. Invalid codes are reported
/// without leaving the camera, so the user can try again.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  /// Set once a valid payload has been returned, so repeated frames cannot pop twice.
  bool _handled = false;

  /// Avoids showing the same "not a pairing code" message for every camera frame.
  String? _lastRejected;

  bool _errorReported = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled || !mounted) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;

      final PairingPayload payload;
      try {
        payload = PairingPayload.parse(raw);
      } on FormatException catch (error) {
        if (_lastRejected != raw) {
          _lastRejected = raw;
          _showMessage(error.message);
        }
        continue;
      }

      _handled = true;
      Navigator.of(context).pop(payload);
      return;
    }
  }

  void _onDetectError(Object error, StackTrace _) {
    // A camera/frame error must never bring down the scanner. Report it once.
    if (!mounted || _errorReported) return;
    _errorReported = true;
    _showMessage('Camera error: $error');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan pairing QR code'),
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            onDetect: _onDetect,
            onDetectError: _onDetectError,
          ),
          Positioned.fill(
            child: SafeArea(
              child: IgnorePointer(
                child: Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'Point your camera at the QR code shown on your PC.',
                        style: TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const Spacer(),
                    AspectRatio(
                      aspectRatio: 1,
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 56),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white70, width: 3),
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                    const Spacer(),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 24),
                      child: Text(
                        'Hold steady — scanning…',
                        style: TextStyle(
                          color: Colors.white,
                          shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
