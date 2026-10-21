import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

void main() {
  const token = 'Qm5y1xk2Qm5y1xk2Qm5y1xk2Qm5y1xk2';
  const payload = PairingPayload(
    id: 'k3j9x0qa2mzp',
    name: 'Recámara de Valdo',
    host: '192.168.68.50',
    port: 8080,
    token: token,
  );

  test('ida y vuelta por el URI', () {
    final uri = payload.toUri().toString();
    expect(uri, startsWith('proyector://pair?'));
    final back = PairingPayload.parse(uri);
    expect(back.id, payload.id);
    expect(back.name, 'Recámara de Valdo');
    expect(back.host, payload.host);
    expect(back.port, 8080);
    expect(back.token, token);
    expect(back.baseUrl.toString(), 'http://192.168.68.50:8080');
  });

  test('rechaza QR ajenos', () {
    expect(PairingPayload.tryParse('https://youtube.com'), isNull);
    expect(PairingPayload.tryParse('hola'), isNull);
    expect(() => PairingPayload.parse('otro://pair?v=1'), throwsFormatException);
    expect(() => PairingPayload.parse('proyector://otro?v=1'), throwsFormatException);
  });

  test('rechaza una versión más nueva', () {
    final uri = payload.toUri().replace(queryParameters: {...payload.toUri().queryParameters, 'v': '2'});
    expect(() => PairingPayload.parse(uri.toString()), throwsFormatException);
  });

  test('rechaza token corto, id raro y puerto inválido', () {
    final base = payload.toUri().queryParameters;
    String withParam(String k, String v) =>
        Uri(scheme: 'proyector', host: 'pair', queryParameters: {...base, k: v}).toString();
    expect(PairingPayload.tryParse(withParam('t', 'corto')), isNull);
    expect(PairingPayload.tryParse(withParam('id', 'MAYUS-123')), isNull);
    expect(PairingPayload.tryParse(withParam('p', '0')), isNull);
    expect(PairingPayload.tryParse(withParam('p', '70000')), isNull);
    expect(PairingPayload.tryParse(withParam('p', 'abc')), isNull);
    expect(PairingPayload.tryParse(withParam('h', '')), isNull);
  });

  test('ignora params desconocidos y pone nombre por defecto', () {
    final base = payload.toUri().queryParameters;
    final uri = Uri(scheme: 'proyector', host: 'pair', queryParameters: {...base, 'n': '  ', 'x': 'y'});
    final p = PairingPayload.parse(uri.toString());
    expect(p.name, 'Proyector');
    expect(p.id, payload.id);
  });

  test('ids y tokens generados cumplen el formato y no se repiten', () {
    final ids = {for (var i = 0; i < 100; i++) randomScreenId()};
    final tokens = {for (var i = 0; i < 100; i++) randomUrlSafe(32)};
    expect(ids.length, 100);
    expect(tokens.length, 100);
    for (final id in ids) {
      expect(RegExp(r'^[a-z0-9]{12}$').hasMatch(id), isTrue);
    }
    for (final t in tokens) {
      expect(RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(t), isTrue);
    }
    // Y lo que genera el proyector se puede meter en un QR y leer de vuelta.
    final p = PairingPayload(id: ids.first, name: 'Sala', host: '10.0.0.2', port: 8080, token: tokens.first);
    expect(PairingPayload.parse(p.toUri().toString()).token, tokens.first);
  });
}
