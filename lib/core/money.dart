/// Exact arbitrary scale decimal money. Rounds HALF_UP only for display.
class Money implements Comparable<Money> {
  final BigInt units;
  final int scale;
  Money._(this.units, this.scale);
  factory Money.parse(String text) {
    if (!RegExp(r'^-?\d+(\.\d+)?$').hasMatch(text)) {
      throw const FormatException('Invalid decimal');
    }
    final p = text.split('.');
    return Money._(BigInt.parse(p.join()), p.length == 2 ? p[1].length : 0);
  }
  BigInt _at(int s) => units * BigInt.from(10).pow(s - scale);
  Money operator -(Money other) {
    final s = scale > other.scale ? scale : other.scale;
    return Money._(_at(s) - other._at(s), s);
  }

  Money divide100() => Money._(units, scale + 2);
  Money get nonNegative => units.isNegative ? Money.parse('0') : this;
  @override
  int compareTo(Money other) {
    final s = scale > other.scale ? scale : other.scale;
    return _at(s).compareTo(other._at(s));
  }

  String get display {
    BigInt n;
    if (scale <= 2) {
      n = _at(2);
    } else {
      final d = BigInt.from(10).pow(scale - 2);
      n = (units.abs() + d ~/ BigInt.two) ~/ d;
      if (units.isNegative) n = -n;
    }
    final s = n.abs().toString().padLeft(3, '0');
    return '${n.isNegative ? '-' : ''}${s.substring(0, s.length - 2)}.${s.substring(s.length - 2)}';
  }
}

String moneyText(Object? value, {bool cents = false}) {
  try {
    final m = Money.parse(value.toString());
    return (cents ? m.divide100() : m).display;
  } catch (_) {
    return '—';
  }
}

String? calculatedPayment(Map<String, dynamic> detail) {
  final items = detail['tradeOrderItem'];
  final discounts = detail['promotionList'];
  if (items is! List || items.length != 1 || discounts is! List) return null;
  try {
    var amount = Money.parse((items.single as Map)['originPrice'].toString());
    final seen = <String>{};
    for (final p in discounts) {
      final type = (p as Map)['promotionType']?.toString();
      if (type == null || !seen.add(type)) return null;
      amount = amount - Money.parse(p['discountAmount'].toString());
    }
    return amount.nonNegative.display;
  } catch (_) {
    return null;
  }
}
