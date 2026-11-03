import 'package:flutter_test/flutter_test.dart';
import 'package:proyector/identity.dart';
import 'package:proyector/state.dart';

void main() {
  ReceiverState open() => ReceiverState(ReceiverIdentity.ephemeral())..showPanel(ReceiverPanel.qr);

  test('the pairing panel shows a 6-digit code and closing it clears it', () {
    final s = open();
    expect(s.shortCode, matches(RegExp(r'^\d{6}$')));
    s.showPanel(ReceiverPanel.home);
    expect(s.shortCode, isNull);
    expect(s.redeemShortCode('123456'), isFalse);
  });

  test('a code works once', () {
    final s = open();
    final code = s.shortCode!;
    expect(s.redeemShortCode(code), isTrue);
    expect(s.shortCode, isNot(code));
    expect(s.redeemShortCode(code), isFalse);
  });

  test('five misses rotate the code', () {
    final s = open();
    final code = s.shortCode!;
    final wrong = code == '000000' ? '111111' : '000000';
    for (var i = 0; i < 4; i++) {
      expect(s.redeemShortCode(wrong), isFalse);
    }
    expect(s.shortCode, code);
    expect(s.redeemShortCode(wrong), isFalse);
    expect(s.shortCode, isNot(code));
  });
}
