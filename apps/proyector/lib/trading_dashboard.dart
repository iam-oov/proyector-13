import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'home_theme.dart';
import 'state.dart';

/// Acciones en el centro del inicio: P&L del día grande con abierto,
/// realizado y total; a la derecha una placa por posición con el precio de
/// Yahoo (las que quepan). Se actualiza cada minuto.
class TradingStats extends StatelessWidget {
  const TradingStats({super.key, required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pal = HomePalette.of(context);
    final s = state.stats;
    final small = text.bodyMedium?.copyWith(color: pal.muted);
    final open = state.quotes.values.any((q) => q.isMarketOpen);
    // Cuánto van arriba o abajo las posiciones abiertas contra lo invertido en
    // ellas (precio de entrada × acciones). Solo lo abierto: lo ya vendido no
    // entra arriba ni abajo, así el % no se infla al cerrar con ganancia.
    final invested = s.positions.fold(0.0, (sum, p) => sum + p.cost);
    final unrealized = s.unrealizedPnl;
    final openPct = unrealized == null || invested == 0
        ? null
        : unrealized / invested * 100;
    // Sin fondo propio: va directo sobre el fondo del inicio, como la barra
    // de arriba, y el ancho que ocupaba el relleno es para las posiciones.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      // Dos columnas a todo el alto: a la izquierda el encabezado y el P&L
      // (36% del ancho, entre 200 y 320 dp); a la derecha las posiciones.
      child: LayoutBuilder(
        builder: (context, box) {
          final leftWidth = (box.maxWidth * 0.36).clamp(200.0, 320.0);
          final narrow = leftWidth < 260;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: s.positions.isEmpty ? box.maxWidth : leftWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.show_chart,
                          size: 20,
                          color: pal.accent,
                        ),
                        const SizedBox(width: 8),
                        Text('Trading', style: text.titleMedium),
                        const SizedBox(width: 10),
                        if (state.quotesAt != null)
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: _MarketPill(open: open),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Text('P&L del día', style: small),
                        const Spacer(),
                        if (state.quotesLoading)
                          Text('Actualizando…', style: small?.copyWith(fontSize: 12))
                        else if (state.nextQuotesAt != null)
                          _Countdown(
                            until: state.nextQuotesAt!,
                            style: small?.copyWith(fontSize: 12),
                          ),
                      ],
                    ),
                    // Solo si Yahoo falló.
                    if (state.quotesError != null)
                      Text(
                        state.quotesError!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: small?.copyWith(fontSize: 12),
                      ),
                    // Crece hasta llenar el alto y el ancho de su columna (el
                    // ancho de las posiciones no cambia).
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: FittedBox(
                          fit: BoxFit.contain,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            money(s.dayTotal),
                            style: text.displayLarge?.copyWith(
                              color: pnlColor(pal, s.dayTotal),
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Angosta (con Spotify al lado): en 2×2 para que no se
                    // encojan cada una a su manera.
                    if (narrow) ...[
                      Row(
                        children: [
                          _MiniStat('Abierto', s.unrealizedPnl),
                          _MiniStat('Total', s.totalPnl),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          _MiniStat('% abierto', openPct, percent: true),
                          _MiniStat('Realizado', s.realizedToday),
                        ],
                      ),
                    ] else
                      Row(
                        children: [
                          _MiniStat('Abierto', s.unrealizedPnl),
                          _MiniStat('Total', s.totalPnl),
                          _MiniStat('% abierto', openPct, percent: true),
                          _MiniStat('Realizado', s.realizedToday),
                        ],
                      ),
                  ],
                ),
              ),
              if (s.positions.isNotEmpty) ...[
                const SizedBox(width: 20),
                Expanded(
                  // Pocas posiciones: una placa por posición que se reparte
                  // el alto; las altas muestran también cantidad y promedio.
                  // Las bajas y la tabla (si no caben como placas) llevan
                  // encabezado de columnas; la tabla se parte en dos solo si
                  // ni así caben.
                  child: LayoutBuilder(
                    builder: (context, box) {
                      const gap = 6.0;
                      const head = _PositionHeader.height;
                      final all = s.positions;
                      final tall =
                          (box.maxHeight - gap * (all.length - 1)) /
                          all.length;
                      if (tall >= 64) {
                        return Column(
                          children: [
                            for (final (i, pos) in all.indexed) ...[
                              if (i > 0) const SizedBox(height: gap),
                              Expanded(
                                child: _PositionFocus(
                                  position: pos,
                                  radius: 12,
                                  padding: EdgeInsets.zero,
                                  child: _PositionPlate(pos),
                                ),
                              ),
                            ],
                          ],
                        );
                      }
                      final body = box.maxHeight - head;
                      final plates = ((body + gap) / (30 + gap)).floor();
                      if (all.length <= plates) {
                        return Column(
                          children: [
                            // Alineado con el texto de las placas (borde de
                            // foco + relleno de la placa).
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 16),
                              child: _PositionHeader(),
                            ),
                            for (final (i, pos) in all.indexed) ...[
                              if (i > 0) const SizedBox(height: gap),
                              Expanded(
                                child: _PositionFocus(
                                  position: pos,
                                  radius: 12,
                                  padding: EdgeInsets.zero,
                                  child: _PositionPlate(pos),
                                ),
                              ),
                            ],
                          ],
                        );
                      }
                      final perColumn = (body / _PositionLine.height)
                          .floor()
                          .clamp(1, all.length);
                      final columns = all.length <= perColumn ? 1 : 2;
                      final rows = (all.length / columns).ceil().clamp(
                        1,
                        perColumn,
                      );
                      return Row(
                        children: [
                          for (var c = 0; c < columns; c++) ...[
                            if (c > 0) const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                children: [
                                  // Alineado con el texto de los renglones
                                  // (borde de foco + relleno).
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: _PositionFocus.inset,
                                    ),
                                    child: _PositionHeader(
                                      showPrice: columns == 1,
                                    ),
                                  ),
                                  for (final pos in all.skip(c * rows).take(rows))
                                    SizedBox(
                                      height: body / rows,
                                      child: _PositionFocus(
                                        position: pos,
                                        child: _PositionLine(
                                          pos,
                                          showPrice: columns == 1,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

}

class _PositionPlate extends StatelessWidget {
  const _PositionPlate(this.p);

  final Position p;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pal = HomePalette.of(context);
    final price = p.quote == null ? '—' : money(p.quote!.price, sign: false);
    final qty = p.qty == p.qty.roundToDouble()
        ? p.qty.toStringAsFixed(0)
        : p.qty.toStringAsFixed(2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: pal.text.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          // Placa baja: todo en una línea.
          if (box.maxHeight < 64) return _PositionLine(p);
          // Placa alta: símbolo y P&L grandes, con cantidad, promedio y precio.
          final big = text.headlineSmall?.copyWith(fontWeight: FontWeight.w600);
          final small = text.bodyMedium?.copyWith(color: pal.muted);
          return Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.symbol, style: big),
                    Text(
                      '$qty acc. · prom. ${money(p.avgEntry, sign: false)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: small,
                    ),
                  ],
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    money(p.unrealized),
                    style: big?.copyWith(color: pnlColor(pal, p.unrealized)),
                  ),
                  Text(
                    '${pct(p.unrealizedPct)} · $price',
                    style: small,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// "AAPL  $348.22  $115.00  2.500  +$496.44  +248.22%" en una línea; si no cabe se
/// encoge entera (nunca parte un precio en dos renglones), igual que su
/// encabezado.
class _PositionLine extends StatelessWidget {
  const _PositionLine(this.p, {this.showPrice = true});

  /// Alto mínimo de un renglón de la tabla.
  static const height = 18.0;

  final Position p;
  final bool showPrice;

  @override
  Widget build(BuildContext context) {
    final pal = HomePalette.of(context);
    final cell = TextStyle(fontSize: 13, color: pal.text);
    return _Columns(
      showPrice: showPrice,
      height: height,
      symbol: Text(
        p.symbol,
        maxLines: 1,
        style: cell.copyWith(fontWeight: FontWeight.w600),
      ),
      qty: Text(
        p.qty.toStringAsFixed(3),
        maxLines: 1,
        textAlign: TextAlign.right,
        style: cell,
      ),
      entry: Text(
        money(p.avgEntry, sign: false),
        maxLines: 1,
        style: cell,
      ),
      price: Text(
        p.quote == null ? '—' : money(p.quote!.price, sign: false),
        maxLines: 1,
        style: cell,
      ),
      pnl: Text(
        money(p.unrealized),
        maxLines: 1,
        textAlign: TextAlign.right,
        style: cell.copyWith(color: pnlColor(pal, p.unrealized) ?? pal.text),
      ),
      percent: Text(
        pct(p.unrealizedPct),
        maxLines: 1,
        textAlign: TextAlign.right,
        style: cell.copyWith(
          fontSize: 12,
          color: pnlColor(pal, p.unrealizedPct) ?? pal.text,
        ),
      ),
    );
  }
}

/// Qué significa cada columna de las posiciones.
class _PositionHeader extends StatelessWidget {
  const _PositionHeader({this.showPrice = true});

  static const height = 18.0;

  final bool showPrice;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 11, color: HomePalette.of(context).muted);
    return SizedBox(
      height: height,
      child: _Columns(
        showPrice: showPrice,
        height: height,
        symbol: Text('Símbolo', maxLines: 1, style: style),
        qty: Text(
          'Cantidad',
          maxLines: 1,
          textAlign: TextAlign.right,
          style: style,
        ),
        entry: Text('Precio IN', maxLines: 1, style: style),
        price: Text('Precio actual', maxLines: 1, style: style),
        pnl: Text(
          'P&L',
          maxLines: 1,
          textAlign: TextAlign.right,
          style: style,
        ),
        percent: Text(
          '%',
          maxLines: 1,
          textAlign: TextAlign.right,
          style: style,
        ),
      ),
    );
  }
}

/// Las columnas de las posiciones con anchos fijos de diseño; todo el
/// renglón se encoge junto si no cabe, así encabezado y números quedan
/// alineados. Sin `showPrice` (tabla en dos columnas) quedan símbolo, P&L y %.
class _Columns extends StatelessWidget {
  const _Columns({
    required this.showPrice,
    required this.height,
    required this.symbol,
    required this.qty,
    required this.entry,
    required this.price,
    required this.pnl,
    required this.percent,
  });

  final bool showPrice;
  final double height;
  final Widget symbol;
  final Widget qty;
  final Widget entry;
  final Widget price;
  final Widget pnl;
  final Widget percent;

  static const _gap = 12.0;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: SizedBox(
      width: showPrice ? 448 : 212,
      height: height,
      // Mismo aire entre todas las columnas.
      child: Row(
        children: [
          Expanded(child: symbol),
          if (showPrice) ...[
            SizedBox(width: 72, child: price),
            const SizedBox(width: _gap),
            SizedBox(width: 72, child: entry),
            const SizedBox(width: _gap),
            SizedBox(width: 56, child: qty),
          ],
          const SizedBox(width: _gap),
          SizedBox(width: 78, child: pnl),
          const SizedBox(width: _gap),
          SizedBox(width: 62, child: percent),
        ],
      ),
    ),
  );
}

/// Placa o renglón de una posición que se puede elegir con el control: con
/// foco se marca con el borde del tema y OK abre el detalle.
class _PositionFocus extends StatefulWidget {
  const _PositionFocus({
    required this.position,
    required this.child,
    this.radius = 8,
    this.padding = const EdgeInsets.symmetric(horizontal: 6),
  });

  /// Borde (2) + relleno (6): lo que el encabezado se recorre para alinear.
  static const inset = 8.0;

  final Position position;
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  State<_PositionFocus> createState() => _PositionFocusState();
}

class _PositionFocusState extends State<_PositionFocus> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final pal = HomePalette.of(context);
    final radius = BorderRadius.circular(widget.radius);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: radius,
        onTap: () => showPositionDetail(context, widget.position),
        onFocusChange: (f) => setState(() => _focused = f),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: widget.padding,
          decoration: BoxDecoration(
            borderRadius: radius,
            color: _focused ? pal.text.withValues(alpha: 0.08) : null,
            // El borde siempre ocupa su lugar: con foco no mueve el texto.
            border: Border.all(
              color: _focused ? pal.focus : Colors.transparent,
              width: 2,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Detalle de una posición (OK sobre ella en el inicio): resultado, precios,
/// lo invertido y cada compra. Atrás lo cierra.
Future<void> showPositionDetail(BuildContext context, Position p) {
  final pal = HomePalette.of(context);
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => Theme(data: pal.theme, child: _PositionDetail(p)),
  );
}

class _PositionDetail extends StatelessWidget {
  const _PositionDetail(this.p);

  final Position p;

  @override
  Widget build(BuildContext context) {
    final pal = HomePalette.of(context);
    final text = Theme.of(context).textTheme;
    final price = p.quote?.price;
    final buys = [...p.trades]..sort((a, b) => a.openedAt.compareTo(b.openedAt));
    final muted = text.bodyMedium?.copyWith(color: pal.muted);
    final cell = text.bodyLarge?.copyWith(color: pal.text);
    return Dialog(
      backgroundColor: pal.brightness == Brightness.light
          ? Colors.white
          : const Color(0xFF26262A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 60, vertical: 28),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    p.symbol,
                    style: text.headlineMedium?.copyWith(
                      color: pal.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${p.side == TradeSide.long ? 'Largo' : 'Corto'} · '
                        '${p.qty.toStringAsFixed(3)} acciones',
                        style: muted,
                      ),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        money(p.unrealized),
                        style: text.headlineMedium?.copyWith(
                          color: pnlColor(pal, p.unrealized) ?? pal.text,
                        ),
                      ),
                      Text(
                        pct(p.unrealizedPct),
                        style: text.titleMedium?.copyWith(
                          color: pnlColor(pal, p.unrealizedPct) ?? pal.muted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 18),
              // Dos renglones de tres datos.
              Row(
                children: [
                  _DetailStat(
                    'Precio actual',
                    price == null ? '—' : money(price, sign: false),
                  ),
                  _DetailStat('Precio IN', money(p.avgEntry, sign: false)),
                  _DetailStat('Invertido', money(p.cost, sign: false)),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _DetailStat(
                    'Valor actual',
                    price == null ? '—' : money(price * p.qty, sign: false),
                  ),
                  _DetailStat(
                    'P&L de hoy',
                    money(p.dayPnl(DateTime.now())),
                    color: pnlColor(pal, p.dayPnl(DateTime.now())),
                  ),
                  _DetailStat(
                    'Comprada',
                    buys.isEmpty ? '—' : _date(buys.first.openedAt),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                buys.length == 1 ? 'Compra' : 'Compras',
                style: text.titleSmall?.copyWith(color: pal.text),
              ),
              const SizedBox(height: 6),
              // Encabezado y una línea por compra (con scroll si son muchas).
              Row(
                children: [
                  Expanded(child: Text('Fecha', style: muted)),
                  Expanded(child: Text('Cantidad', style: muted)),
                  Expanded(child: Text('Precio IN', style: muted)),
                  Expanded(
                    child: Text(
                      'Invertido',
                      textAlign: TextAlign.right,
                      style: muted,
                    ),
                  ),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final t in buys)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(child: Text(_date(t.openedAt), style: cell)),
                              Expanded(
                                child: Text(
                                  t.qty.toStringAsFixed(3),
                                  style: cell,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  money(t.entryPrice, sign: false),
                                  style: cell,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  money(t.entryPrice * t.qty, sign: false),
                                  textAlign: TextAlign.right,
                                  style: cell,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  'Atrás para cerrar',
                  style: text.bodySmall?.copyWith(color: pal.muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

class _DetailStat extends StatelessWidget {
  const _DetailStat(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final pal = HomePalette.of(context);
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.bodySmall?.copyWith(color: pal.muted)),
          Text(
            value,
            style: text.titleMedium?.copyWith(color: color ?? pal.text),
          ),
        ],
      ),
    );
  }
}

/// "● Mercado abierto" en verde, o cerrado en gris.
class _MarketPill extends StatelessWidget {
  const _MarketPill({required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) {
    final pal = HomePalette.of(context);
    final color = open ? pal.up : pal.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            open ? 'Mercado abierto' : 'Mercado cerrado',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(this.label, this.value, {this.percent = false});

  final String label;
  final double? value;

  /// El valor es un porcentaje ("+3.21%") en vez de dinero.
  final bool percent;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pal = HomePalette.of(context);
    return Expanded(
      // Aire a la derecha: que una cifra no se lea pegada a la siguiente.
      child: Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Etiqueta y monto en una línea: si no caben, se encogen.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                style: text.bodySmall?.copyWith(color: pal.muted),
              ),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                percent ? pct(value) : money(value),
                style: text.titleSmall?.copyWith(color: pnlColor(pal, value)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "⟳ 0:42" hasta la siguiente consulta a Yahoo; se redibuja cada segundo.
class _Countdown extends StatefulWidget {
  const _Countdown({required this.until, this.style});

  final DateTime until;
  final TextStyle? style;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      '⟳ ${countdownText(widget.until.difference(DateTime.now()))}',
      style: widget.style,
    );
  }
}

/// Verde si gana, rojo si pierde (del tema); null en cero o sin dato.
Color? pnlColor(HomePalette pal, double? v) {
  if (v == null || v == 0) return null;
  return v > 0 ? pal.up : pal.down;
}
