import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mebius/src/internal/broadcast_engine.dart';

/// Authoritative check of normalizeConnectionState against the REAL enum names
/// flutter_webrtc fires, not hand-written strings. The trap: `disconnected`
/// contains `connected` as a substring and `connecting` must not read as
/// either, so the matcher's order is load-bearing. If flutter_webrtc renames a
/// member, this test is what catches the silent mis-mapping.
void main() {
  group('normalizeConnectionState over real enum names', () {
    test('every RTCPeerConnectionState maps to the right token', () {
      final want = <RTCPeerConnectionState, String>{
        RTCPeerConnectionState.RTCPeerConnectionStateClosed: 'closed',
        RTCPeerConnectionState.RTCPeerConnectionStateFailed: 'failed',
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected: 'disconnected',
        RTCPeerConnectionState.RTCPeerConnectionStateNew: 'new',
        RTCPeerConnectionState.RTCPeerConnectionStateConnecting: 'connecting',
        RTCPeerConnectionState.RTCPeerConnectionStateConnected: 'connected',
      };
      // Guard: if the enum grows a member, force us to classify it here.
      expect(want.length, RTCPeerConnectionState.values.length);
      want.forEach((state, token) {
        expect(normalizeConnectionState(state.name), token, reason: state.name);
      });
    });

    test('every RTCIceConnectionState maps to the right token', () {
      final want = <RTCIceConnectionState, String>{
        RTCIceConnectionState.RTCIceConnectionStateNew: 'new',
        RTCIceConnectionState.RTCIceConnectionStateChecking: 'checking',
        RTCIceConnectionState.RTCIceConnectionStateCompleted: 'completed',
        RTCIceConnectionState.RTCIceConnectionStateConnected: 'connected',
        RTCIceConnectionState.RTCIceConnectionStateCount: 'new',
        RTCIceConnectionState.RTCIceConnectionStateFailed: 'failed',
        RTCIceConnectionState.RTCIceConnectionStateDisconnected: 'disconnected',
        RTCIceConnectionState.RTCIceConnectionStateClosed: 'closed',
      };
      expect(want.length, RTCIceConnectionState.values.length);
      want.forEach((state, token) {
        expect(normalizeConnectionState(state.name), token, reason: state.name);
      });
    });

    test('the two failure tokens are exactly failed and disconnected', () {
      // These are the only tokens ConnectionWatch acts on as a failure path;
      // a rename that broke them would silently disable error reporting.
      expect(normalizeConnectionState('RTCPeerConnectionStateFailed'), 'failed');
      expect(
        normalizeConnectionState('RTCIceConnectionStateDisconnected'),
        'disconnected',
      );
    });
  });
}
