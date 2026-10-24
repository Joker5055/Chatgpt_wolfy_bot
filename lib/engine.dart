import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const tradingPairs = <String>[
  'BTCUSDT', 'ETHUSDT', 'BNBUSDT', 'SOLUSDT',
  'XRPUSDT', 'DOGEUSDT', 'ADAUSDT',
];
const timeframes = <String>['15m', '1h', '4h'];
const strategyNames = <String>[
  'EMA Cross', 'RSI + Bollinger', 'MACD + Trend', 'Supertrend',
  'ADX Trend', 'Stoch + CCI', 'Breakout 20', 'Engulfing',
];

double mean(List<double> xs) =>
    xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;
double maxD(double a, double b) => math.max(a, b).toDouble();
double minD(double a, double b) => math.min(a, b).toDouble();

List<double> emaSeries(List<double> values, int period) {
  if (values.isEmpty) return [];
  final k = 2.0 / (period + 1);
  final out = <double>[values.first];
  for (final v in values.skip(1)) {
    out.add(v * k + out.last * (1 - k));
  }
  return out;
}
double ema(List<double> values, int period) {
  final s = emaSeries(values, period);
  return s.isEmpty ? 0 : s.last;
}

double rsi(List<double> closes, [int period = 14]) {
  if (closes.length <= period) return 50;
  double gain = 0, loss = 0;
  for (var i = closes.length - period; i < closes.length; i++) {
    final d = closes[i] - closes[i - 1];
    if (d > 0) gain += d; else loss -= d;
  }
  if (loss == 0) return gain == 0 ? 50 : 100;
  final rs = gain / loss;
  return 100 - 100 / (1 + rs);
}

class Candle {
  final DateTime time;
  final double open, high, low, close, volume;
  const Candle({
    required this.time, required this.open, required this.high,
    required this.low, required this.close, required this.volume,
  });

  factory Candle.fromBinance(List<dynamic> row) => Candle(
    time: DateTime.fromMillisecondsSinceEpoch((row[0] as num).toInt(), isUtc: true),
    open: (row[1] as num).toDouble(),
    high: (row[2] as num).toDouble(),
    low: (row[3] as num).toDouble(),
    close: (row[4] as num).toDouble(),
    volume: (row[5] as num).toDouble(),
  );
}

double atr(List<Candle> cs, [int period = 14]) {
  if (cs.length < 2) return 0;
  final start = math.max(1, cs.length - period).toInt();
  final ranges = <double>[];
  for (var i = start; i < cs.length; i++) {
    final c = cs[i], prev = cs[i - 1].close;
    ranges.add(maxD(c.high - c.low,
        maxD((c.high - prev).abs(), (c.low - prev).abs())));
  }
  return mean(ranges);
}

double cci(List<Candle> cs, [int period = 20]) {
  if (cs.length < period) return 0;
  final part = cs.sublist(cs.length - period);
  final tp = part.map((c) => (c.high + c.low + c.close) / 3).toList();
  final avg = mean(tp);
  final dev = mean(tp.map((v) => (v - avg).abs()).toList());
  return dev == 0 ? 0 : (tp.last - avg) / (0.015 * dev);
}

class Indicators {
  final double ema9, ema21, ema50, ema200, rsi, macd, macdSignal;
  final double bbUpper, bbLower, stochastic, cci, adx, plusDI, minusDI, atr;
  final double supertrend;
  final bool supertrendBullish, bullishEngulfing, bearishEngulfing;
  final bool breakoutUp, breakoutDown;

  const Indicators({
    required this.ema9, required this.ema21, required this.ema50,
    required this.ema200, required this.rsi, required this.macd,
    required this.macdSignal, required this.bbUpper, required this.bbLower,
    required this.stochastic, required this.cci, required this.adx,
    required this.plusDI, required this.minusDI, required this.atr,
    required this.supertrend, required this.supertrendBullish,
    required this.bullishEngulfing, required this.bearishEngulfing,
    required this.breakoutUp, required this.breakoutDown,
  });

  factory Indicators.calculate(List<Candle> cs) {
    final closes = cs.map((c) => c.close).toList();
    final last = cs.isEmpty ? null : cs.last;
    final e9 = ema(closes, 9), e21 = ema(closes, 21);
    final e50 = ema(closes, 50), e200 = ema(closes, 200);
    final currentAtr = atr(cs);
    final rsiValue = rsi(closes);

    final sample = closes.length >= 20 ? closes.sublist(closes.length - 20) : closes;
    final avg = mean(sample);
    final dev = math.sqrt(mean(sample.map((v) => (v - avg) * (v - avg)).toList()));

    double stoch = 50;
    if (cs.length >= 14) {
      final recent = cs.sublist(cs.length - 14);
      final hi = recent.map((c) => c.high).reduce(maxD);
      final lo = recent.map((c) => c.low).reduce(minD);
      if (hi > lo) stoch = 100 * (last!.close - lo) / (hi - lo);
    }

    // Directional movement and DX average; a practical Wilder-style approximation.
    double plus = 0, minus = 0, trSum = 0;
    if (cs.length >= 15) {
      for (var i = cs.length - 14; i < cs.length; i++) {
        final a = cs[i], b = cs[i - 1];
        final up = a.high - b.high, down = b.low - a.low;
        if (up > down && up > 0) plus += up;
        if (down > up && down > 0) minus += down;
        trSum += maxD(a.high - a.low,
            maxD((a.high - b.close).abs(), (a.low - b.close).abs()));
      }
    }
    final pdi = trSum == 0 ? 0.0 : 100 * plus / trSum;
    final mdi = trSum == 0 ? 0.0 : 100 * minus / trSum;
    final diSum = pdi + mdi;
    final adxValue = diSum == 0 ? 0.0 : 100 * (pdi - mdi).abs() / diSum;

    final macdSeries = <double>[];
    for (var i = 0; i < closes.length; i++) {
      final part = closes.sublist(0, i + 1);
      macdSeries.add(ema(part, 12) - ema(part, 26));
    }
    final macdValue = closes.isEmpty ? 0.0 : ema(closes, 12) - ema(closes, 26);
    final signal = ema(macdSeries, 9);

    final bull = cs.length >= 2 &&
        cs[cs.length - 2].close < cs[cs.length - 2].open &&
        cs.last.close > cs.last.open &&
        cs.last.close >= cs[cs.length - 2].open &&
        cs.last.open <= cs[cs.length - 2].close;
    final bear = cs.length >= 2 &&
        cs[cs.length - 2].close > cs[cs.length - 2].open &&
        cs.last.close < cs.last.open &&
        cs.last.close <= cs[cs.length - 2].open &&
        cs.last.open >= cs[cs.length - 2].close;

    bool upBreak = false, downBreak = false;
    if (cs.length >= 21) {
      final w = cs.sublist(cs.length - 21, cs.length - 1);
      upBreak = cs.last.close > w.map((c) => c.high).reduce(maxD);
      downBreak = cs.last.close < w.map((c) => c.low).reduce(minD);
    }

    // Supertrend band approximation using current ATR; production use should
    // validate a full recursive Supertrend implementation against reference data.
    final mid = last == null ? 0.0 : (last.high + last.low) / 2;
    final stBull = last != null && last.close >= mid;
    return Indicators(
      ema9: e9, ema21: e21, ema50: e50, ema200: e200, rsi: rsiValue,
      macd: macdValue, macdSignal: signal, bbUpper: avg + 2 * dev,
      bbLower: avg - 2 * dev, stochastic: stoch, cci: cci(cs),
      adx: adxValue, plusDI: pdi, minusDI: mdi, atr: currentAtr,
      supertrend: mid + (stBull ? -3 : 3) * currentAtr,
      supertrendBullish: stBull, bullishEngulfing: bull,
      bearishEngulfing: bear, breakoutUp: upBreak, breakoutDown: downBreak,
    );
  }
}

class MarketService {
  final http.Client client;
  final Map<String, List<Candle>> candleCache = {};
  MarketService({http.Client? client}) : client = client ?? http.Client();
  String _key(String p, String tf) => '$p:$tf';

  Future<List<Candle>> fetchCandles(String pair, String tf, {int limit = 1000}) async {
    Object? lastError;
    for (final base in [
      'https://data-api.binance.vision/api/v3/klines',
      'https://api.binance.com/api/v3/klines',
    ]) {
      try {
        final uri = Uri.parse(base).replace(queryParameters: {
          'symbol': pair, 'interval': tf, 'limit': '$limit',
        });
        final res = await client.get(uri).timeout(const Duration(seconds: 12));
        if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
        final rows = jsonDecode(res.body) as List<dynamic>;
        final result = rows.map((r) => Candle.fromBinance(r as List<dynamic>)).toList();
        if (result.isEmpty) throw Exception('Empty candle response');
        candleCache[_key(pair, tf)] = result;
        return result;
      } catch (e) {
        lastError = e;
      }
    }
    final cached = candleCache[_key(pair, tf)];
    if (cached != null && cached.isNotEmpty) return cached;
    throw Exception('Market data unavailable: $lastError');
  }

  Future<double> fetchPrice(String pair) async {
    Object? lastError;
    for (final base in [
      'https://data-api.binance.vision/api/v3/ticker/price',
      'https://api.binance.com/api/v3/ticker/price',
    ]) {
      try {
        final uri = Uri.parse(base).replace(queryParameters: {'symbol': pair});
        final res = await client.get(uri).timeout(const Duration(seconds: 6));
        if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
        return (jsonDecode(res.body)['price'] as num).toDouble();
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Price unavailable: $lastError');
  }

  Stream<Candle> watchKlines(String pair, String tf) {
    late final StreamController<Candle> controller;
    WebSocketChannel? channel;
    StreamSubscription? subscription;
    var cancelled = false;
    var reconnecting = false;

    controller = StreamController<Candle>(onCancel: () async {
      cancelled = true;
      await subscription?.cancel();
      await channel?.sink.close();
    });

    Future<void> connect() async {
      if (cancelled || reconnecting) return;
      reconnecting = true;
      try {
        channel = WebSocketChannel.connect(Uri.parse(
          'wss://data-stream.binance.vision/ws/${pair.toLowerCase()}@kline_$tf',
        ));
        await channel!.ready.timeout(const Duration(seconds: 10));
        subscription = channel!.stream.listen((event) {
          try {
            final msg = jsonDecode(event as String) as Map<String, dynamic>;
            final k = msg['k'] as Map<String, dynamic>;
            controller.add(Candle(
              time: DateTime.fromMillisecondsSinceEpoch((k['t'] as num).toInt(), isUtc: true),
              open: double.parse(k['o'].toString()),
              high: double.parse(k['h'].toString()),
              low: double.parse(k['l'].toString()),
              close: double.parse(k['c'].toString()),
              volume: double.parse(k['v'].toString()),
            ));
          } catch (_) {}
        }, onError: (_) => reconnect(), onDone: reconnect);
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 4));
        reconnecting = false;
        await connect();
        return;
      }
      reconnecting = false;
    }

    Future<void> reconnect() async {
      if (cancelled) return;
      await Future<void>.delayed(const Duration(seconds: 3));
      reconnecting = false;
      await connect();
    }

    connect().then<void>((_) {});
    return controller.stream;
  }

  void dispose() => client.close();
}

int higherTrend(List<Candle> cs) {
  if (cs.length < 200) return 0;
  final closes = cs.map((c) => c.close).toList();
  final e50 = ema(closes, 50), e200 = ema(closes, 200);
  if (closes.last > e50 && e50 > e200) return 1;
  if (closes.last < e50 && e50 < e200) return -1;
  return 0;
}

List<int> strategyVotes(List<Candle> cs) {
  if (cs.length < 200) return List.filled(8, 0);
  final i = Indicators.calculate(cs);
  final closes = cs.map((c) => c.close).toList();
  final e9 = emaSeries(closes, 9), e21 = emaSeries(closes, 21);
  final prev9 = e9[e9.length - 2], prev21 = e21[e21.length - 2];
  return [
    prev9 <= prev21 && i.ema9 > i.ema21 ? 1 :
      prev9 >= prev21 && i.ema9 < i.ema21 ? -1 : 0,
    i.rsi < 30 && closes.last <= i.bbLower ? 1 :
      i.rsi > 70 && closes.last >= i.bbUpper ? -1 : 0,
    i.macd > i.macdSignal && closes.last > i.ema200 ? 1 :
      i.macd < i.macdSignal && closes.last < i.ema200 ? -1 : 0,
    i.supertrendBullish ? 1 : -1,
    i.adx >= 25 && i.plusDI > i.minusDI ? 1 :
      i.adx >= 25 && i.minusDI > i.plusDI ? -1 : 0,
    i.stochastic < 20 && i.cci < -100 ? 1 :
      i.stochastic > 80 && i.cci > 100 ? -1 : 0,
    i.breakoutUp ? 1 : i.breakoutDown ? -1 : 0,
    i.bullishEngulfing ? 1 : i.bearishEngulfing ? -1 : 0,
  ];
}

class StrategyResult {
  final String name;
  final int direction, trades;
  final double winRate, expectancy;
  final bool proven;
  const StrategyResult({
    required this.name, required this.direction, required this.trades,
    required this.winRate, required this.expectancy, required this.proven,
  });
}

class BacktestResult {
  final List<StrategyResult> strategies;
  final int direction, votes;
  final double confidence;
  final String reason;
  const BacktestResult({
    required this.strategies, required this.direction, required this.votes,
    required this.confidence, required this.reason,
  });
  bool get valid => direction != 0 && votes >= 2;
}

class _Outcome {
  final double net;
  const _Outcome(this.net);
  bool get win => net > 0;
}

List<_Outcome> _simulate(List<Candle> cs, int start, int end, int strategy) {
  final out = <_Outcome>[];
  var index = start;
  while (index < end - 1) {
    final window = cs.sublist(0, index + 1);
    final trend = higherTrend(window);
    final votes = strategyVotes(window);
    final direction = votes[strategy];
    if (trend == 0 || direction == 0 || direction != trend) {
      index++;
      continue;
    }
    final entry = cs[index].close, volatility = atr(window);
    if (entry <= 0 || volatility <= 0) { index++; continue; }
    final stop = entry - direction * 1.5 * volatility;
    final target = entry + direction * 3 * volatility;
    final lastIndex = math.min(end - 1, index + 12).toInt();
    var exitPrice = cs[lastIndex].close;
    var exitIndex = lastIndex;
    for (var j = index + 1; j <= lastIndex; j++) {
      final c = cs[j];
      final sl = direction == 1 ? c.low <= stop : c.high >= stop;
      final tp = direction == 1 ? c.high >= target : c.low <= target;
      if (sl) { exitPrice = stop; exitIndex = j; break; }
      if (tp) { exitPrice = target; exitIndex = j; break; }
    }
    final gross = direction * (exitPrice - entry) / entry;
    out.add(_Outcome(gross - 0.002));
    index = exitIndex + 1;
  }
  return out;
}

BacktestResult backtest(List<Candle> cs) {
  if (cs.length < 250) {
    return const BacktestResult(strategies: [], direction: 0, votes: 0,
      confidence: 0, reason: 'Kam candles hain; kam az kam 250 chahiye.');
  }
  final split = (cs.length * .6).floor();
  final rows = <StrategyResult>[];
  var longs = 0, shorts = 0, provenCount = 0;
  final latestVotes = strategyVotes(cs);
  final trend = higherTrend(cs);

  for (var s = 0; s < 8; s++) {
    final train = _simulate(cs, 200, split, s);
    final test = _simulate(cs, split, cs.length, s);
    final trainExp = mean(train.map((o) => o.net).toList());
    final testExp = mean(test.map((o) => o.net).toList());
    final proven = train.length >= 10 && test.length >= 10 &&
        trainExp > 0 && testExp > 0;
    final direction = proven && latestVotes[s] == trend ? trend : 0;
    if (direction == 1) longs++;
    if (direction == -1) shorts++;
    if (proven) provenCount++;
    rows.add(StrategyResult(
      name: strategyNames[s], direction: direction, trades: test.length,
      winRate: test.isEmpty ? 0 : test.where((o) => o.win).length / test.length * 100,
      expectancy: testExp * 100, proven: proven,
    ));
  }
  final direction = longs >= 2 ? 1 : shorts >= 2 ? -1 : 0;
  final i = Indicators.calculate(cs);
  final feeRoom = cs.last.close > 0 && (1.5 * i.atr / cs.last.close) > .003;
  final validDirection = feeRoom ? direction : 0;
  final reason = trend == 0 ? 'Trend clear nahi; trade avoid karo.' :
    provenCount < 2 ? 'Dono periods mein 2 proven strategies nahi.' :
    direction == 0 ? 'Do proven strategies same direction mein agree nahi kartin.' :
    !feeRoom ? 'ATR range fees ke muqablay mein chhoti hai.' :
    'Conditions match karti hain; profit guaranteed nahi.';
  return BacktestResult(
    strategies: rows, direction: validDirection,
    votes: math.max(longs, shorts).toInt(),
    confidence: provenCount / 8 * 100,
    reason: reason,
  );
}
