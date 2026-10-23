import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'home_theme.dart';

/// "USD $18.72" en la barra del inicio: el dólar en pesos de Yahoo (MXN=X),
/// cada 5 min (1 min si falló). Sin datos no muestra nada.
class DollarText extends StatefulWidget {
  const DollarText({super.key});

  @override
  State<DollarText> createState() => _DollarTextState();
}

class _DollarTextState extends State<DollarText> {
  final _yahoo = YahooFinance();
  // El último precio sobrevive a que el inicio se cree de nuevo (al volver del
  // QR): se muestra de inmediato mientras se vuelve a consultar.
  static Quote? _last;
  Quote? _quote = _last;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final q = await _yahoo.quote('MXN=X');
    if (!mounted) return;
    if (q != null) setState(() => _quote = _last = q);
    _timer = Timer(Duration(minutes: q == null ? 1 : 5), _refresh);
  }

  @override
  Widget build(BuildContext context) {
    final q = _quote;
    if (q == null) return const SizedBox.shrink();
    final p = HomePalette.of(context);
    final style = Theme.of(context).textTheme.titleMedium;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('USD', style: style?.copyWith(color: p.muted)),
        const SizedBox(width: 6),
        Text(
          '\$${q.price.toStringAsFixed(2)}',
          style: style?.copyWith(color: p.text, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}
