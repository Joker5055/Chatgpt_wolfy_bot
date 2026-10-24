import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const tradingPairs = <String>[
  'BTCUSDT',
  'ETHUSDT',
  'BNBUSDT',
  'SOLUSDT',
  'XRPUSDT',
  'DOGEUSDT',
  'ADAUSDT',
];

const timeframes = <String>['15m', '1h', '4h'];

const strategyNames = <String>[
  'EMA Cross',
  'RSI + Bollinger',
  'MACD + Trend',
  'Supertrend',
  'ADX Trend',
  'Stoch + CCI',
  'Breakout 20',
  'Engulfing',
];

const feeRate = 0.002; // 0.2% round-trip backtest fee.
const minProvenTrades = 10;

double mean(List<double> values) {
  if (values.isEmpty) return 0;
  return values.reduce((a, b) => a + b) / values.length;
}

double ema(List<double> values, int period) {
  if (values.isEmpty) return 0;
  final multiplier = 2.0 / (period + 1);
  double result = values.first;

  for (final value in values.skip(1)) {
    result = value * multiplier + result * (1 - multiplier);
  }
  return result;
}

List<double> emaSeries(List<double> values, int period) {
  if (values.isEmpty) return [];
  final multiplier = 2.0 / (period + 1);
  final result = <double>[values.first];

  for (final value in values.skip(1)) {
    result.add(value * multiplier + result.last * (1 - multiplier));
  }
  return result;
}

double rsi(List<double> closes, [int period = 14]) {
  if (closes.length <= period) return 50;

  double gains = 0;
  double losses = 0;

  for (int i = closes.length - period; i < closes.length; i++) {
    final change = closes[i] - closes[i - 1];
    if (change > 0) {
      gains += change;
    } else {
      losses -= change;
    }
  }

  if (losses == 0) return 100;
  final rs = gains / losses;
  return 100 - (100 / (1 + rs));
}

double atr(List<Candle> candles, [int period = 14]) {
  if (candles.length < 2) return 0;
  final start = math.max(1, candles.length - period);
  final ranges = <double>[];

  for (int i = start; i < candles.length; i++) {
    final c = candles[i];
    final previous = candles[i - 1].close;

    ranges.add(math.max(
      c.high - c.low,
      math.max(
        (c.high - previous).abs(),
        (c.low - previous).abs(),
      ),
    ));
  }
  return mean(ranges);
}

double cci(List<Candle> candles, [int period = 20]) {
  if (candles.length < period) return 0;
  final recent = candles.sublist(candles.length - period);
  final typical = recent.map((c) => (c.high + c.low + c.close) / 3).toList();
  final average = mean(typical);
  final deviation = mean(typical.map((v) => (v - average).abs()).toList());

  if (deviation == 0) return 0;
  return (typical.last - average) / (0.015 * deviation);
}

class Candle {
  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  const Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  factory Candle.fromBinance(List<dynamic> row) {
    return Candle(
      time: DateTime.fromMillisecondsSinceEpoch(
        (row[0] as num).toInt(),
        isUtc: true,
      ),
      open: (row[1] as num).toDouble(),
      high: (row[2] as num).toDouble(),
      low: (row[3] as num).toDouble(),
      close: (row[4] as num).toDouble(),
      volume: (row[5] as num).toDouble(),
    );
  }

  factory Candle.fromJson(Map<String, dynamic> json) {
    return Candle(
      time: DateTime.fromMillisecondsSinceEpoch(
        (json['time'] as num).toInt(),
        isUtc: true,
      ),
      open: (json['open'] as num).toDouble(),
      high: (json['high'] as num).toDouble(),
      low: (json['low'] as num).toDouble(),
      close: (json['close'] as num).toDouble(),
      volume: (json['volume'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'time': time.millisecondsSinceEpoch,
        'open': open,
        'high': high,
        'low': low,
        'close': close,
        'volume': volume,
      };
}

class MarketService {
  final http.Client client;
  final Map<String, List<Candle>> cache = {};
  final Map<String, WebSocketChannel> sockets = {};

  MarketService({http.Client? client}) : client = client ?? http.Client();

  String key(String pair, String tf) => '$pair:$tf';

  Future<List<Candle>> fetchCandles(
    String pair,
    String timeframe, {
    int limit = 1000,
  }) async {
    final endpoints = [
      'https://data-api.binance.vision/api/v3/klines',
      'https://api.binance.com/api/v3/klines',
    ];

    Object? lastError;

    for (final base in endpoints) {
      try {
        final uri = Uri.parse(base).replace(queryParameters: {
          'symbol': pair,
          'interval': timeframe,
          'limit': '$limit',
        });

        final response = await client
            .get(uri)
            .timeout(const Duration(seconds: 12));

        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }

        final rows = jsonDecode(response.body) as List<dynamic>;
        final candles = rows
            .map((row) => Candle.fromBinance(row as List<dynamic>))
            .toList();

        if (candles.isEmpty) throw Exception('Empty candle response');

        cache[key(pair, timeframe)] = candles;
        return candles;
      } catch (e) {
        lastError = e;
      }
    }

    final old = cache[key(pair, timeframe)];
    if (old != null && old.isNotEmpty) return old;

    throw Exception('Market data unavailable: $lastError');
  }

  Future<double> fetchPrice(String pair) async {
    final endpoints = [
      'https://data-api.binance.vision/api/v3/ticker/price',
      'https://api.binance.com/api/v3/ticker/price',
    ];

    Object? lastError;

    for (final base in endpoints) {
      try {
        final uri = Uri.parse(base).replace(
          queryParameters: {'symbol': pair},
        );
        final response = await client
            .get(uri)
            .timeout(const Duration(seconds: 6));

        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }

        return (jsonDecode(response.body)['price'] as num).toDouble();
      } catch (e) {
        lastError = e;
      }
    }

    throw Exception('Price unavailable: $lastError');
  }

  Stream<Candle> watchKlines(String pair, String timeframe) {
    final controller = StreamController<Candle>();
    WebSocketChannel? channel;
    StreamSubscription? subscription;
    var closed = false;

    Future<void> connect() async {
      if (closed) return;

      try {
        channel = WebSocketChannel.connect(
          Uri.parse(
            'wss://data-stream.binance.vision/ws/'
            '${pair.toLowerCase()}@kline_$timeframe',
          ),
        );

        await channel!.ready.timeout(const Duration(seconds: 10));

        subscription = channel!.stream.listen(
          (event) {
            try {
              final json = jsonDecode(event as String)
                  as Map<String, dynamic>;
              final kline = json['k'] as Map<String, dynamic>;

              controller.add(Candle(
                time: DateTime.fromMillisecondsSinceEpoch(
                  (kline['t'] as num).toInt(),
                  isUtc: true,
                ),
                open: double.parse(kline['o'].toString()),
                high: double.parse(kline['h'].toString()),
                low: double.parse(kline['l'].toString()),
                close: double.parse(kline['c'].toString()),
                volume: double.parse(kline['v'].toString()),
              ));
            } catch (_) {
              // Ignore malformed WebSocket messages.
            }
          },
          onError: (_) async {
            await Future<void>.delayed(const Duration(seconds: 3));
            await connect();
          },
          onDone: () async {
            await Future<void>.delayed(const Duration(seconds: 3));
            await connect();
          },
        );
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 5));
        await connect();
      }
    }

    connect().then<void>((_) {});

    controller.onCancel = () async {
      closed = true;
      await subscription?.cancel();
      await channel?.sink.close();
    };

    return controller.stream;
  }

  void dispose() {
    for (final socket in sockets.values) {
      socket.sink.close();
    }
    sockets.clear();
    client.close();
  }
}

class Indicators {
  final double ema9;
  final double ema21;
  final double ema50;
  final double ema200;
  final double rsi;
  final double macd;
  final double macdSignal;
  final double bbUpper;
  final double bbLower;
  final double stochastic;
  final double cci;
  final double adx;
  final double plusDI;
  final double minusDI;
  final double atr;
  final double supertrend;
  final bool supertrendBullish;
  final bool bullishEngulfing;
  final bool bearishEngulfing;
  final bool breakoutUp;
  final bool breakoutDown;

  const Indicators({
    required this.ema9,
    required this.ema21,
    required this.ema50,
    required this.ema200,
    required this.rsi,
    required this.macd,
    required this.macdSignal,
    required this.bbUpper,
    required this.bbLower,
    required this.stochastic,
    required this.cci,
    required this.adx,
    required this.plusDI,
    required this.minusDI,
    required this.atr,
    required this.supertrend,
    required this.supertrendBullish,
    required this.bullishEngulfing,
    required this.bearishEngulfing,
    required this.breakoutUp,
    required this.breakoutDown,
  });

  factory Indicators.calculate(List<Candle> candles) {
    final closes = candles.map((c) => c.close).toList();
    final last = candles.isEmpty ? null : candles.last;
    final e9 = ema(closes, 9);
    final e21 = ema(closes, 21);
    final e50 = ema(closes, 50);
    final e200 = ema(closes, 200);
    final currentRsi = rsi(closes);
    final currentAtr = atr(candles);

    final recent = closes.length >= 20
        ? closes.sublist(closes.length - 20)
        : closes;
    final average = mean(recent);
    final variance = mean(
      recent.map((v) => (v - average) * (v - average)).toList(),
    );
    final deviation = math.sqrt(variance);

    double stochastic = 50;
    if (candles.length >= 14) {
      final sample = candles.sublist(candles.length - 14);
      final highest = sample.map((c) => c.high).reduce(math.max);
      final lowest = sample.map((c) => c.low).reduce(math.min);
      if (highest != lowest) {
        stochastic = 100 * (last!.close - lowest) / (highest - lowest);
      }
    }

    double plusDI = 0;
    double minusDI = 0;
    double adx = 0;

    if (candles.length >= 15) {
      double up = 0, down = 0, tr = 0;
      for (int i = candles.length - 14; i < candles.length; i++) {
        final a = candles[i];
        final b = candles[i - 1];
        final moveUp = a.high - b.high;
        final moveDown = b.low - a.low;

        if (moveUp > moveDown && moveUp > 0) up += moveUp;
        if (moveDown > moveUp && moveDown > 0) down += moveDown;

        tr += math.max(
          a.high - a.low,
          math.max(
            (a.high - b.close).abs(),
            (a.low - b.close).abs(),
          ),
        );
      }

      if (tr > 0) {
        plusDI = 100 * up / tr;
        minusDI = 100 * down / tr;
        final sum = plusDI + minusDI;
        if (sum > 0) adx = 100 * (plusDI - minusDI).abs() / sum;
      }
    }

    final previousCloses =
        closes.length > 1 ? closes.sublist(0, closes.length - 1) : closes;
    final previousMacd = ema(previousCloses, 12) - ema(previousCloses, 26);
    final macdValues = <double>[];
    for (int i = 0; i < closes.length; i++) {
      final part = closes.sublist(0, i + 1);
      macdValues.add(ema(part, 12) - ema(part, 26));
    }
    final macdSignal = ema(macdValues, 9);
    final currentMacd = closes.isEmpty ? 0 : e12(closes) - e26(closes);

    final bullish = candles.length >= 2 &&
        candles[candles.length - 2].close <
            candles[candles.length - 2].open &&
        candles.last.close > candles.last.open &&
        candles.last.close >= candles[candles.length - 2].open &&
        candles.last.open <= candles[candles.length - 2].close;

    final bearish = candles.length >= 2 &&
        candles[candles.length - 2].close >
            candles[candles.length - 2].open &&
        candles.last.close < candles.last.open &&
        candles.last.close <= candles[candles.length - 2].open &&
        candles.last.open >= candles[candles.length - 2].close;

    bool breakoutUp = false, breakoutDown = false;
    if (candles.length >= 21) {
      final window = candles.sublist(candles.length - 21, candles.length - 1);
      final highest = window.map((c) => c.high).reduce(math.max);
      final lowest = window.map((c) => c.low).reduce(math.min);
      breakoutUp = last!.close > highest;
      breakoutDown = last.close < lowest;
    }

    final stBull = last != null && currentAtr > 0 &&
        last.close >= (last.high + last.low) / 2 - 3 * currentAtr;

    return Indicators(
      ema9: e9,
      ema21: e21,
      ema50: e50,
      ema200: e200,
      rsi: currentRsi,
      macd: currentMacd,
      macdSignal: macdSignal,
      bbUpper: average + 2 * deviation,
      bbLower: average - 2 * deviation,
      stochastic: stochastic,
      cci: cci(candles),
      adx: adx,
      plusDI: plusDI,
      minusDI: minusDI,
      atr: currentAtr,
      supertrend: last == null ? 0 : (stBull
          ? (last.high + last.low) / 2 - 3 * currentAtr
          : (last.high + last.low) / 2 + 3 * currentAtr),
      supertrendBullish: stBull,
      bullishEngulfing: bullish,
      bearishEngulfing: bearish,
      breakoutUp: breakoutUp,
      breakoutDown: breakoutDown,
    );
  }
}

double e12(List<double> values) => ema(values, 12);
double e26(List<double> values) => ema(values, 26);

class StrategyResult {
  final String name;
  final int direction;
  final double winRate;
  final int trades;
  final double expectancy;
  final bool proven;

  const StrategyResult({
    required this.name,
    required this.direction,
    required this.winRate,
    required this.trades,
    required this.expectancy,
    required this.proven,
  });
}

class BacktestResult {
  final List<StrategyResult> strategies;
  final int direction;
  final int votes;
  final double confidence;
  final String reason;

  const BacktestResult({
    required this.strategies,
    required this.direction,
    required this.votes,
    required this.confidence,
    required this.reason,
  });

  bool get valid => direction != 0 && votes >= 2;
}

int higherTrend(List<Candle> candles) {
  if (candles.length < 200) return 0;

  final closes = candles.map((c) => c.close).toList();
  final last = closes.last;
  final e50 = ema(closes, 50);
  final e200 = ema(closes, 200);

  if (last > e50 && e50 > e200) return 1;
  if (last < e50 && e50 < e200) return -1;
  return 0;
}

List<int> strategyVotes(List<Candle> candles) {
  if (candles.length < 200) return List.filled(8, 0);

  final i = Indicators.calculate(candles);
  final closes = candles.map((c) => c.close).toList();
  final fastSeries = emaSeries(closes, 9);
  final slowSeries = emaSeries(closes, 21);
  final previousFast = fastSeries[fastSeries.length - 2];
  final previousSlow = slowSeries[slowSeries.length - 2];

  return [
    previousFast <= previousSlow && i.ema9 > i.ema21
        ? 1
        : previousFast >= previousSlow && i.ema9 < i.ema21
            ? -1
            : 0,
    i.rsi < 30 && closes.last <= i.bbLower
        ? 1
        : i.rsi > 70 && closes.last >= i.bbUpper
            ? -1
            : 0,
    i.macd > i.macdSignal && closes.last > i.ema200
        ? 1
        : i.macd < i.macdSignal && closes.last < i.ema200
            ? -1
            : 0,
    i.supertrendBullish ? 1 : -1,
    i.adx >= 25 && i.plusDI > i.minusDI
        ? 1
        : i.adx >= 25 && i.minusDI > i.plusDI
            ? -1
            : 0,
    i.stochastic < 20 && i.cci < -100
        ? 1
        : i.stochastic > 80 && i.cci > 100
            ? -1
            : 0,
    i.breakoutUp ? 1 : i.breakoutDown ? -1 : 0,
    i.bullishEngulfing ? 1 : i.bearishEngulfing ? -1 : 0,
  ];
}

class TradeOutcome {
  final double netReturn;
  final bool win;

  const TradeOutcome(this.netReturn, this.win);
}

List<TradeOutcome> simulate(
  List<Candle> candles,
  int start,
  int end,
  int strategyIndex,
) {
  final results = <TradeOutcome>[];
  int i = start;

  while (i < end - 1) {
    final window = candles.sublist(0, i + 1);
    final trend = higherTrend(window);
    if (trend == 0) {
      i++;
      continue;
    }

    final votes = strategyVotes(window);
    final direction = votes[strategyIndex];

    if (direction == 0 || direction != trend) {
      i++;
      continue;
    }

    final entry = candles[i].close;
    final volatility = atr(window);
    if (entry <= 0 || volatility <= 0) {
      i++;
      continue;
    }

    final stop = entry - direction * 1.5 * volatility;
    final target = entry + direction * 3 * volatility;
    double exitPrice = candles[math.min(end - 1, i + 12)].close;
    int exitIndex = math.min(end - 1, i + 12);

    for (int j = i + 1; j <= exitIndex; j++) {
      final c = candles[j];

      // Conservative rule: if both are hit in one candle, SL wins.
      final slHit = direction == 1
          ? c.low <= stop
          : c.high >= stop;
      final tpHit = direction == 1
          ? c.high >= target
          : c.low <= target;

      if (slHit) {
        exitPrice = stop;
        exitIndex = j;
        break;
      }

      if (tpHit) {
        exitPrice = target;
        exitIndex = j;
        break;
      }
    }

    final gross = direction * (exitPrice - entry) / entry;
    final net = gross - feeRate;
    results.add(TradeOutcome(net, net > 0));
    i = exitIndex + 1;
  }

  return results;
}

BacktestResult backtest(List<Candle> candles) {
  if (candles.length < 250) {
    return BacktestResult(
      strategies: const [],
      direction: 0,
      votes: 0,
      confidence: 0,
      reason: 'Kam candles hain; kam az kam 250 chahiye.',
    );
  }

  final split = (candles.length * 0.6).floor();
  final results = <StrategyResult>[];
  int longVotes = 0, shortVotes = 0, provenCount = 0;

  for (int s = 0; s < 8; s++) {
    final train = simulate(candles, 200, split, s);
    final test = simulate(candles, split, candles.length, s);

    final trainExpectancy = mean(train.map((t) => t.netReturn).toList());
    final testExpectancy = mean(test.map((t) => t.netReturn).toList());
    final enoughTrades = train.length >= minProvenTrades &&
        test.length >= minProvenTrades;
    final proven = enoughTrades &&
        trainExpectancy > 0 &&
        testExpectancy > 0;

    final current = strategyVotes(candles)[s];
    final trend = higherTrend(candles);
    final direction = proven && current == trend ? current : 0;

    if (direction == 1) longVotes++;
    if (direction == -1) shortVotes++;
    if (proven) provenCount++;

    results.add(StrategyResult(
      name: strategyNames[s],
      direction: direction,
      winRate: test.isEmpty
          ? 0
          : test.where((t) => t.win).length / test.length * 100,
      trades: test.length,
      expectancy: testExpectancy * 100,
      proven: proven,
    ));
  }

  final direction = longVotes >= 2
      ? 1
      : shortVotes >= 2
          ? -1
          : 0;

  final i = Indicators.calculate(candles);
  final entry = candles.last.close;
  final stopDistance = 1.5 * i.atr;
  final feesAsFraction = 0.002;

  final enoughRoom = entry > 0 &&
      stopDistance / entry > feesAsFraction * 1.5;

  String reason;
  if (higherTrend(candles) == 0) {
    reason = 'Trend clear nahi; trade avoid karo.';
  } else if (provenCount < 2) {
    reason = 'Kam az kam 2 strategies dono periods mein proven nahi.';
  } else if (dir
