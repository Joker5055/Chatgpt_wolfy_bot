import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'engine.dart';

const green = Color(0xFF00D9A6);
const red = Color(0xFFFF5570);
const muted = Color(0xFF91A0B7);

class HomeScreen extends StatefulWidget {
  final MarketService service;
  const HomeScreen({super.key, required this.service});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}
class _HomeScreenState extends State<HomeScreen> {
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    final pages = [
      SignalsPage(service: widget.service),
      ChartsPage(service: widget.service),
      DemoPage(service: widget.service),
      const LearnPage(),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('🐺 Wolfies Hit Bot')),
      body: Column(children: [
        Expanded(child: IndexedStack(index: tab, children: pages)),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'Demo only • No guaranteed profit • Historical tests are not predictions. Fees, slippage and data outages matter.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: muted),
          ),
        ),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bolt_outlined), label: 'Signals'),
          NavigationDestination(icon: Icon(Icons.candlestick_chart), label: 'Charts'),
          NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), label: 'Demo'),
          NavigationDestination(icon: Icon(Icons.school_outlined), label: 'Seekho'),
        ],
      ),
    );
  }
}

class SignalsPage extends StatefulWidget {
  final MarketService service;
  const SignalsPage({super.key, required this.service});
  @override
  State<SignalsPage> createState() => _SignalsPageState();
}
class _SignalsPageState extends State<SignalsPage> {
  String pair = 'BTCUSDT', tf = '15m';
  List<Candle> candles = [];
  BacktestResult? result;
  bool loading = false;
  String error = '';
  Timer? timer;
  final Map<String, BacktestResult> resultCache = {};
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 30), (_) => load(silent: true));
  }
  Future<void> load({bool silent = false}) async {
    if (loading) return;
    setState(() { loading = true; error = ''; });
    try {
      final data = await widget.service.fetchCandles(pair, tf);
      final key = '$pair:$tf:${data.length}:${data.last.time.millisecondsSinceEpoch}';
      final analysis = resultCache[key] ?? backtest(data);
      resultCache[key] = analysis;
      if (!mounted) return;
      setState(() { candles = data; result = analysis; loading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() { loading = false; error = 'Market data nahi mila. Internet check karke retry karein.'; });
    }
  }
  @override
  void dispose() { timer?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final price = candles.isEmpty ? 0.0 : candles.last.close;
    final signal = result?.valid == true ? (result!.direction == 1 ? 'BUY' : 'SELL') : 'NO TRADE';
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(padding: const EdgeInsets.all(14), children: [
        Row(children: [
          Expanded(child: DropdownButtonFormField<String>(
            value: pair, decoration: const InputDecoration(labelText: 'Pair'),
            items: tradingPairs.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
            onChanged: (v) { if (v != null) { setState(() => pair = v); load(); } },
          )),
          const SizedBox(width: 8),
          Expanded(child: DropdownButtonFormField<String>(
            value: tf, decoration: const InputDecoration(labelText: 'Timeframe'),
            items: timeframes.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
            onChanged: (v) { if (v != null) { setState(() => tf = v); load(); } },
          )),
        ]),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('SELECTED OPPORTUNITY', style: TextStyle(color: muted, fontSize: 11)),
            Text('$pair · $tf', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text(price == 0 ? '--' : '\$${price.toStringAsFixed(4)}', style: const TextStyle(fontSize: 25)),
            Chip(label: Text(signal), backgroundColor: signal == 'BUY' ? green.withValues(alpha: .2) : signal == 'SELL' ? red.withValues(alpha: .2) : Colors.blueGrey.withValues(alpha: .2)),
            Text(result?.reason ?? 'Analysis load ho rahi hai...', style: const TextStyle(color: muted)),
            Text('Backtest confidence: ${(result?.confidence ?? 0).toStringAsFixed(0)}% · Votes: ${result?.votes ?? 0}', style: const TextStyle(color: muted)),
            if (result?.valid == true && candles.isNotEmpty) ...[
              Text('Entry: \$${price.toStringAsFixed(4)}'),
              Text('SL: \$${(price - result!.direction * 1.5 * Indicators.calculate(candles).atr).toStringAsFixed(4)}'),
              Text('TP: \$${(price + result!.direction * 3 * Indicators.calculate(candles).atr).toStringAsFixed(4)}'),
              const Text('Exit rule: maximum 12 candles; stop-loss checked first.'),
            ],
            if (loading) const LinearProgressIndicator(),
            if (error.isNotEmpty) Text(error, style: const TextStyle(color: red)),
            Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: load, icon: const Icon(Icons.refresh), label: const Text('Refresh'))),
          ],
        ))),
        const Text('CANDLE CHART · EMA 9 / EMA 21', style: TextStyle(fontWeight: FontWeight.bold)),
        SizedBox(height: 230, child: Card(child: Padding(
          padding: const EdgeInsets.all(10),
          child: candles.isEmpty ? const Center(child: Text('Loading candles...')) : CustomPaint(painter: CandlePainter(candles), child: const SizedBox.expand()),
        ))),
        const Text('STRATEGIES', style: TextStyle(fontWeight: FontWeight.bold)),
        if (result?.strategies.isEmpty ?? true) const Padding(padding: EdgeInsets.all(12), child: Text('250+ candles aur enough test trades chahiye.', style: TextStyle(color: muted))),
        ...?result?.strategies.map((s) => Card(child: ListTile(
          dense: true, title: Text(s.name),
          subtitle: Text('${s.trades} test trades · ${s.winRate.toStringAsFixed(1)}% win · ${s.expectancy.toStringAsFixed(3)}% expectancy'),
          trailing: Icon(s.proven ? Icons.verified : Icons.hourglass_empty, color: s.proven ? green : muted),
        ))),
        const Text('PAIR SCAN', style: TextStyle(fontWeight: FontWeight.bold)),
        ...tradingPairs.map((p) => ListTile(title: Text(p), trailing: const Icon(Icons.chevron_right), onTap: () { setState(() => pair = p); load(); })),
      ]),
    );
  }
}

class CandlePainter extends CustomPainter {
  final List<Candle> candles;
  CandlePainter(this.candles);
  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty) return;
    final data = candles.length > 60 ? candles.sublist(candles.length - 60) : candles;
    final hi = data.map((c) => c.high).reduce((a,b) => math.max(a,b).toDouble());
    final lo = data.map((c) => c.low).reduce((a,b) => math.min(a,b).toDouble());
    if (hi <= lo) return;
    double y(double p) => size.height - (p - lo) / (hi - lo) * size.height;
    final step = size.width / data.length;
    final wick = Paint()..strokeWidth = 1;
    final body = Paint();
    for (var n = 0; n < data.length; n++) {
      final c = data[n], x = (n + .5) * step, up = c.close >= c.open;
      wick.color = up ? green : red; body.color = up ? green : red;
      canvas.drawLine(Offset(x,y(c.high)), Offset(x,y(c.low)), wick);
      final top = y(math.max(c.open,c.close).toDouble());
      final bottom = y(math.min(c.open,c.close).toDouble());
      canvas.drawRect(Rect.fromLTRB(x - math.max(1.0,step*.3),top,x + math.max(1.0,step*.3),math.max(top+1,bottom).toDouble()), body);
    }
    final closes = data.map((c) => c.close).toList();
    void overlay(int period, Color color) {
      final values = emaSeries(closes, period);
      final paint = Paint()..color = color..strokeWidth = 1.5..style = PaintingStyle.stroke;
      final path = Path();
      for (var n=0;n<values.length;n++) {
        final point = Offset((n+.5)*step,y(values[n]));
        if (n==0) path.moveTo(point.dx,point.dy); else path.lineTo(point.dx,point.dy);
      }
      canvas.drawPath(path,paint);
    }
    overlay(9, Colors.amber); overlay(21, Colors.lightBlueAccent);
  }
  @override
  bool shouldRepaint(covariant CandlePainter oldDelegate) => !identical(oldDelegate.candles, candles);
}

class ChartsPage extends StatefulWidget {
  final MarketService service;
  const ChartsPage({super.key, required this.service});
  @override
  State<ChartsPage> createState() => _ChartsPageState();
}
class _ChartsPageState extends State<ChartsPage> {
  String tf = '15m';
  @override
  Widget build(BuildContext context) => Column(children: [
    Padding(padding: const EdgeInsets.all(10), child: SegmentedButton<String>(
      segments: timeframes.map((t) => ButtonSegment(value: t, label: Text(t))).toList(),
      selected: {tf}, onSelectionChanged: (v) => setState(() => tf = v.first),
    )),
    Expanded(child: GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: .85, crossAxisSpacing: 8, mainAxisSpacing: 8),
      itemCount: tradingPairs.length,
      itemBuilder: (_, i) => MiniChart(pair: tradingPairs[i], tf: tf, service: widget.service),
    )),
  ]);
}
class MiniChart extends StatefulWidget {
  final String pair, tf; final MarketService service;
  const MiniChart({super.key, required this.pair, required this.tf, required this.service});
  @override
  State<MiniChart> createState() => _MiniChartState();
}
class _MiniChartState extends State<MiniChart> {
  List<Candle> data = []; String badge = 'WAIT'; Timer? timer;
  @override
  void initState() { super.initState(); load(); timer = Timer.periodic(const Duration(seconds: 30), (_) => load()); }
  @override
  void didUpdateWidget(covariant MiniChart oldWidget) { super.didUpdateWidget(oldWidget); if (oldWidget.tf != widget.tf) load(); }
  Future<void> load() async {
    try {
      final d = await widget.service.fetchCandles(widget.pair, widget.tf);
      final b = backtest(d);
      if (!mounted) return;
      setState(() { data = d; badge = b.valid ? (b.direction == 1 ? 'BUY' : 'SELL') : 'WAIT'; });
    } catch (_) {}
  }
  @override
  void dispose() { timer?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(8), child: Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.pair, style: const TextStyle(fontWeight: FontWeight.bold)),
      Text(data.isEmpty ? '--' : '\$${data.last.close.toStringAsFixed(2)}', style: const TextStyle(color: muted)),
      Expanded(child: data.isEmpty ? const Center(child: CircularProgressIndicator()) : CustomPaint(painter: CandlePainter(data), child: const SizedBox.expand())),
      Align(alignment: Alignment.centerRight, child: Chip(label: Text(badge))),
    ],
  )));
}

class _Position {
  final String pair; final int direction;
  final double entry, qty, stop, target;
  final DateTime opened;
  _Position(this.pair,this.direction,this.entry,this.qty,this.stop,this.target,this.opened);
}
class DemoPage extends StatefulWidget {
  final MarketService service;
  const DemoPage({super.key, required this.service});
  @override
  State<DemoPage> createState() => _DemoPageState();
}
class _DemoPageState extends State<DemoPage> {
  double balance=1000, totalPnl=0;
  String pair='BTCUSDT', side='BUY';
  bool auto=false, busy=false;
  final amount=TextEditingController(text:'100');
  final sl=TextEditingController(text:'1.5');
  final tp=TextEditingController(text:'3');
  final prices=<String,double>{};
  final positions=<_Position>[];
  final history=<double>[];
  Timer? poller;
  @override
  void initState() { super.initState(); poller=Timer.periodic(const Duration(seconds:2), (_) => poll()); poll(); }
  Future<void> poll() async {
    if (busy) return; busy=true;
    try {
      final pairs=positions.map((p)=>p.pair).toSet();
      for (final p in pairs) { try { prices[p]=await widget.service.fetchPrice(p); } catch (_) {} }
      if (auto && positions.length < 3) {
        for (final p in tradingPairs) {
          if (positions.any((x)=>x.pair==p)) continue;
          try {
            final candles=await widget.service.fetchCandles(p,'15m');
            final b=backtest(candles);
            if (!b.valid) continue;
            final price=candles.last.close, volatility=Indicators.calculate(candles).atr;
            if (volatility<=0 || balance<=0) continue;
            final risk=balance*.01;
            final amountToUse=math.min(balance*.95, risk/(1.5*volatility/price + .002));
            if (!mounted) return;
            setState(()=>_open(p,b.direction,amountToUse,price,1.5*volatility/price*100,3*volatility/price*100));
            break;
          } catch (_) {}
        }
      }
      for (final p in tradingPairs.take(7)) {
        if (!prices.containsKey(p)) { try { prices[p]=await widget.service.fetchPrice(p); } catch (_) {} }
      }
      if (!mounted) return;
      setState(() {
        final closing=< _Position >[];
        for(final p in positions) {
          final price=prices[p.pair]; if(price==null) continue;
          final stopHit=p.direction==1 ? price<=p.stop : price>=p.stop;
          final targetHit=p.direction==1 ? price>=p.target : price<=p.target;
          final timeExit=DateTime.now().difference(p.opened).inMinutes>=180;
          if(stopHit||targetHit||timeExit) closing.add(p);
        }
        for(final p in closing) _close(p, prices[p.pair] ?? p.entry);
      });
    } catch (_) {
      // Keep the demo alive on intermittent network errors.
    } finally { busy=false; }
  }
  void _open(String p,int dir,double amount,double price,double slPct,double tpPct) {
    if(price<=0 || amount<=0 || amount>balance || positions.length>=3) return;
    final fee=amount*.001;
    balance-=amount+fee;
    positions.add(_Position(p,dir,price,amount/price,
      price*(1-dir*slPct/100),price*(1+dir*tpPct/100),DateTime.now()));
  }
  void _close(_Position p,double price) {
    if(!positions.contains(p)) return;
    final gross=p.direction*(price-p.entry)*p.qty;
    final exitValue=p.qty*price, fee=exitValue*.001, net=gross-fee;
    balance+=exitValue-fee; totalPnl+=net; history.add(net); positions.remove(p);
  }
  Future<void> manualTrade() async {
    try {
      final price=await widget.service.fetchPrice(pair);
      final a=double.tryParse(amount.text)??0, s=double.tryParse(sl.text)??1.5, t=double.tryParse(tp.text)??3;
      if(!mounted)return;
      setState(()=>_open(pair,side=='BUY'?1:-1,a,price,s,t));
    } catch (_) {}
  }
  Future<void> takeBest() async {
    for(final p in tradingPairs) {
      try {
        final cs=await widget.service.fetchCandles(p,'15m'), b=backtest(await widget.service.fetchCandles(p,'15m'));
        if(!b.valid)continue;
        final price=cs.last.close, vol=Indicators.calculate(cs).atr;
        final a=math.min(balance*.95,(balance*.01)/math.max(.0001,1.5*vol/price+.002));
        if(!mounted)return;
        setState(()=>_open(p,b.direction,a,price,1.5*vol/price*100,3*vol/price*100));
        return;
      } catch (_) {}
    }
  }
  @override
  void dispose(){poller?.cancel();amount.dispose();sl.dispose();tp.dispose();super.dispose();}
  @override
  Widget build(BuildContext context) {
    final wins=history.where((v)=>v>0).length;
    final winRate=history.isEmpty?0.0:wins/history.length*100;
    return ListView(padding:const EdgeInsets.all(14),children:[
      Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Text('VIRTUAL WALLET',style:TextStyle(color:muted)),
        Text('\$${balance.toStringAsFixed(2)} USDT',style:const TextStyle(fontSize:28,fontWeight:FontWeight.bold)),
        Text('Total PnL: \$${totalPnl.toStringAsFixed(2)}',style:TextStyle(color:totalPnl>=0?green:red)),
        Text('Closed trades: ${history.length} · Win rate: ${winRate.toStringAsFixed(1)}%'),
      ]))),
      const Text('MANUAL PAPER TRADE',style:TextStyle(fontWeight:FontWeight.bold)),
      const SizedBox(height:8),
      DropdownButtonFormField<String>(value:pair,decoration:const InputDecoration(labelText:'Pair'),items:tradingPairs.map((p)=>DropdownMenuItem(value:p,child:Text(p))).toList(),onChanged:(v){if(v!=null)setState(()=>pair=v);}),
      const SizedBox(height:8),
      DropdownButtonFormField<String>(value:side,decoration:const InputDecoration(labelText:'Direction'),items:const [DropdownMenuItem(value:'BUY',child:Text('BUY / Long')),DropdownMenuItem(value:'SELL',child:Text('SELL / Short'))],onChanged:(v){if(v!=null)setState(()=>side=v);}),
      const SizedBox(height:8),
      TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Amount (USDT)')),
      const SizedBox(height:8),
      Row(children:[Expanded(child:TextField(controller:sl,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'SL %'))),const SizedBox(width:8),Expanded(child:TextField(controller:tp,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'TP %')))]),
      const SizedBox(height:8),
      FilledButton(onPressed:manualTrade,child:const Text('Open Demo Trade')),
      OutlinedButton(onPressed:takeBest,child:const Text('Take Best Valid Signal')),
      SwitchListTile(title:const Text('Auto Demo Bot'),subtitle:const Text('Valid signals · max 3 open positions'),value:auto,onChanged:(v)=>setState(()=>auto=v)),
      const Divider(),
      const Text('OPEN POSITIONS',style:TextStyle(fontWeight:FontWeight.bold)),
      if(positions.isEmpty) const Text('Koi open position nahi.'),
      ...positions.map((p){
        final price=prices[p.pair]??p.entry,pnl=p.direction*(price-p.entry)*p.qty;
        return Card(child:ListTile(title:Text('${p.pair} · ${p.direction==1?'BUY':'SELL'}'),subtitle:Text('Entry ${p.entry.toStringAsFixed(4)} · SL ${p.stop.toStringAsFixed(4)} · TP ${p.target.toStringAsFixed(4)}\nUnrealized PnL: \$${pnl.toStringAsFixed(2)}'),trailing:IconButton(icon:const Icon(Icons.close),onPressed:()=>setState(()=>_close(p,prices[p.pair]??p.entry))));
      }),
      const Divider(),
      const Text('HISTORY',style:TextStyle(fontWeight:FontWeight.bold)),
      ...history.reversed.take(30).map((v)=>ListTile(title:Text(v>=0?'Profit':'Loss'),trailing:Text('\$${v.toStringAsFixed(2)}',style:TextStyle(color:v>=0?green:red)))),
      OutlinedButton(onPressed:()=>showDialog<void>(context:context,builder:(ctx)=>AlertDialog(title:const Text('Reset demo?'),content:const Text('Wallet aur trade history reset ho jayegi.'),actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Cancel')),
        FilledButton(onPressed:(){setState(() { balance=1000; totalPnl=0; positions.clear(); history.clear(); prices.clear(); auto=false; }); Navigator.pop(ctx);},child:const Text('Reset')),
      ])),child:const Text('Reset Demo Account')),
    ]);
  }
}

class LearnPage extends StatelessWidget {
  const LearnPage({super.key});
  static const lessons=<Map<String,String>>[
    {'title':'USDT kya hai?','body':'USDT aik stablecoin hai jo USD ke qareeb rehne ke liye design kiya gaya hai, lekin value aur issuer risk zero nahi.'},
    {'title':'Spot vs Futures','body':'Spot mein aap asset buy/sell karte ho. Futures contracts aur leverage involve kar sakte hain; beginners leverage se door rahen.'},
    {'title':'Long / BUY','body':'Long mein aap price barhne ki expectation rakhte ho.'},
    {'title':'Short / SELL','body':'Short mein aap price girne ki expectation rakhte ho. Futures mein loss bohat tezi se barh sakta hai.'},
    {'title':'Stop-loss','body':'Planned exit level jo loss limit karne mein madad karta hai. Real markets mein slippage ki wajah se fill price alag ho sakti hai.'},
    {'title':'RSI','body':'Momentum indicator. RSI 70 se upar ya 30 se neeche hona akela trade signal nahi.'},
    {'title':'EMA','body':'EMA recent prices ko zyada weight deta hai. EMA cross clue ho sakta hai, guarantee nahi.'},
    {'title':'1% rule','body':'Aksar traders aik trade mein capital ka 1% ya kam risk plan karte hain. Position size stop distance aur fees se calculate hota hai.'},
    {'title':'Kab trade nahi karna?','body':'Trend unclear ho, signals disagree karein, data stale ho, fees zyada hon, ya aap emotional hon to NO TRADE bhi aik achha decision hai.'},
    {'title':'Demo first','body':'Pehle paper trading practice karein. Backtest past data par hai; fees, slippage aur future conditions results badal sakte hain. Profit guaranteed nahi.'},
  ];
  @override
  Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(14),children:[
    const Text('SEEKHO 🐺',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
    const Text('Crypto basics — simple Hinglish mein',style:TextStyle(color:muted)),
    const SizedBox(height:10),
    ...lessons.map((l)=>Card(child:ExpansionTile(title:Text(l['title']!),childrenPadding:const EdgeInsets.fromLTRB(16,0,16,16),children:[Text(l['body']!)]))),
  ]);
}
