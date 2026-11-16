import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CashOfficeApp());
}

class CashOfficeApp extends StatelessWidget {
  const CashOfficeApp({super.key, this.testDaily, this.testDebts});
  final List<CashTransaction>? testDaily;
  final List<DebtAccount>? testDebts;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'دفتر الكاش',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E)),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      builder: (ctx, child) => Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink()),
      home: CashHomeScreen(testDaily: testDaily, testDebts: testDebts),
    );
  }
}

enum TxType {
  deposit('deposit', 'إيداع', Color(0xFF15803D), Color(0xFFDCFCE7), Icons.south_west_rounded),
  withdraw('withdraw', 'سحب', Color(0xFF1D4ED8), Color(0xFFDBEAFE), Icons.north_east_rounded);
  const TxType(this.code, this.label, this.color, this.bgColor, this.icon);
  final String code, label;
  final Color color, bgColor;
  final IconData icon;
  static TxType fromCode(String c) => c == 'withdraw' ? TxType.withdraw : TxType.deposit;
}

class CashTransaction {
  const CashTransaction({this.id, required this.type, required this.amount, required this.profit, required this.createdAt});
  final int? id;
  final TxType type;
  final double amount, profit;
  final DateTime createdAt;
  Map<String, Object?> toMap() => {
    'type': type.code,
    'amount': amount,
    'profit': profit,
    'date_key': Fmt.toDateKey(createdAt),
    'month_key': Fmt.toMonthKey(createdAt),
    'created_at': createdAt.toIso8601String(),
  };
  factory CashTransaction.fromMap(Map<String, Object?> m) => CashTransaction(
    id: m['id'] as int?,
    type: TxType.fromCode((m['type'] as String?) ?? 'deposit'),
    amount: ((m['amount'] as num?) ?? 0).toDouble(),
    profit: ((m['profit'] as num?) ?? 0).toDouble(),
    createdAt: DateTime.tryParse((m['created_at'] as String?) ?? '') ?? DateTime.now(),
  );
}

class DebtLogEntry {
  const DebtLogEntry({required this.debtId, required this.kind, required this.delta, required this.balanceAfter, required this.note, required this.createdAt});
  final int debtId;
  final String kind, note;
  final double delta, balanceAfter;
  final DateTime createdAt;
  factory DebtLogEntry.fromMap(Map<String, Object?> m) => DebtLogEntry(
    debtId: ((m['debt_id'] as num?) ?? 0).toInt(),
    kind: (m['kind'] as String?) ?? 'init',
    delta: ((m['delta'] as num?) ?? 0).toDouble(),
    balanceAfter: ((m['balance_after'] as num?) ?? 0).toDouble(),
    note: (m['note'] as String?) ?? '',
    createdAt: DateTime.tryParse((m['created_at'] as String?) ?? '') ?? DateTime.now(),
  );
}

class DebtAccount {
  const DebtAccount({this.id, required this.person, required this.amount, required this.lastClearedAmount, required this.direction, required this.note, required this.settled, required this.logs});
  final int? id;
  final String person, direction, note;
  final double amount, lastClearedAmount;
  final bool settled;
  final List<DebtLogEntry> logs;
  bool get isForMe => direction != 'on_me';
}

class DailySummaryRow {
  const DailySummaryRow({required this.dateKey, required this.txCount, required this.totalVolume, required this.depositVolume, required this.withdrawVolume, required this.totalGain});
  final String dateKey;
  final int txCount;
  final double totalVolume, depositVolume, withdrawVolume, totalGain;
}

class CashDatabase {
  CashDatabase._();
  static final CashDatabase instance = CashDatabase._();
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(p.join(dbPath, 'daftar_el_cash_v2.db'), version: 1, onCreate: (db, v) async {
      await db.execute('CREATE TABLE transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, amount REAL NOT NULL, profit REAL NOT NULL, date_key TEXT NOT NULL, month_key TEXT NOT NULL, created_at TEXT NOT NULL)');
      await db.execute('CREATE INDEX idx_tx_date ON transactions(date_key)');
      await db.execute('CREATE INDEX idx_tx_month ON transactions(month_key)');
      await db.execute('CREATE TABLE debts (id INTEGER PRIMARY KEY AUTOINCREMENT, person TEXT NOT NULL, amount REAL NOT NULL, last_cleared REAL NOT NULL DEFAULT 0, direction TEXT NOT NULL, note TEXT NOT NULL DEFAULT "", settled INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL)');
      await db.execute('CREATE TABLE debt_logs (id INTEGER PRIMARY KEY AUTOINCREMENT, debt_id INTEGER NOT NULL, kind TEXT NOT NULL, delta REAL NOT NULL, balance_after REAL NOT NULL, note TEXT NOT NULL DEFAULT "", created_at TEXT NOT NULL)');
    });
    return _db!;
  }

  Future<int> insertTx(CashTransaction tx) async => (await database).insert('transactions', tx.toMap());
  Future<void> deleteTx(int id) async => (await database).delete('transactions', where: 'id = ?', whereArgs: [id]);

  Future<List<CashTransaction>> getTxForDate(String dateKey) async {
    final rows = await (await database).query('transactions', where: 'date_key = ?', whereArgs: [dateKey], orderBy: 'id DESC');
    return rows.map(CashTransaction.fromMap).toList();
  }

  Future<List<DailySummaryRow>> getMonthly(String monthKey) async {
    final rows = await (await database).rawQuery('''
      SELECT date_key, COUNT(*) AS tx_count, SUM(amount) AS total_volume,
        SUM(CASE WHEN type = 'deposit' THEN amount ELSE 0 END) AS dep_vol,
        SUM(CASE WHEN type = 'withdraw' THEN amount ELSE 0 END) AS wit_vol,
        SUM(profit) AS total_gain
      FROM transactions WHERE month_key = ? GROUP BY date_key ORDER BY date_key DESC
    ''', [monthKey]);
    return rows.map((r) => DailySummaryRow(
      dateKey: (r['date_key'] as String?) ?? '',
      txCount: ((r['tx_count'] as num?) ?? 0).toInt(),
      totalVolume: ((r['total_volume'] as num?) ?? 0).toDouble(),
      depositVolume: ((r['dep_vol'] as num?) ?? 0).toDouble(),
      withdrawVolume: ((r['wit_vol'] as num?) ?? 0).toDouble(),
      totalGain: ((r['total_gain'] as num?) ?? 0).toDouble(),
    )).toList();
  }

  Future<List<DebtAccount>> getAllDebts() async {
    final db = await database;
    final debtRows = await db.query('debts', orderBy: 'settled ASC, updated_at DESC, id DESC');
    final logRows = await db.query('debt_logs', orderBy: 'id DESC');
    final mapLogs = <int, List<DebtLogEntry>>{};
    for (final lr in logRows) {
      final e = DebtLogEntry.fromMap(lr);
      mapLogs.putIfAbsent(e.debtId, () => []).add(e);
    }
    return debtRows.map((m) {
      final id = (m['id'] as int?) ?? 0;
      return DebtAccount(
        id: id,
        person: (m['person'] as String?) ?? '',
        amount: ((m['amount'] as num?) ?? 0).toDouble(),
        lastClearedAmount: ((m['last_cleared'] as num?) ?? 0).toDouble(),
        direction: (m['direction'] as String?) ?? 'for_me',
        note: (m['note'] as String?) ?? '',
        settled: ((m['settled'] as num?) ?? 0) == 1,
        logs: mapLogs[id] ?? const [],
      );
    }).toList();
  }

  Future<String> addOrMergeDebt(String person, double amount, String direction, String note) async {
    final db = await database;
    final nowIso = DateTime.now().toIso8601String();
    final existing = await db.query('debts', where: 'settled = 0 AND direction = ? AND person = ?', whereArgs: [direction, person], limit: 1);
    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      final prevNote = ((existing.first['note'] as String?) ?? '').trim();
      final updated = (((existing.first['amount'] as num?) ?? 0).toDouble()) + amount;
      final mergedNote = note.isEmpty ? prevNote : (prevNote.isEmpty ? note : '$prevNote • $note');
      await db.update('debts', {'amount': updated, 'note': mergedNote, 'updated_at': nowIso}, where: 'id = ?', whereArgs: [id]);
      await db.insert('debt_logs', {'debt_id': id, 'kind': 'add', 'delta': amount, 'balance_after': updated, 'note': note.isEmpty ? 'إضافة على القديم' : note, 'created_at': nowIso});
      return 'تمت زيادة ${Fmt.money(amount)} ج على حساب $person (الباقي: ${Fmt.money(updated)} ج)';
    }
    final newId = await db.insert('debts', {'person': person, 'amount': amount, 'last_cleared': amount, 'direction': direction, 'note': note, 'settled': 0, 'updated_at': nowIso});
    await db.insert('debt_logs', {'debt_id': newId, 'kind': 'init', 'delta': amount, 'balance_after': amount, 'note': note.isEmpty ? 'بداية الحساب' : note, 'created_at': nowIso});
    return 'تم تسجيل حساب الآجل باسم $person';
  }

  Future<String> adjustDebt(DebtAccount debt, bool isIncrease, double delta, String note) async {
    final db = await database;
    final id = debt.id!;
    final nowIso = DateTime.now().toIso8601String();
    final cur = debt.settled ? 0.0 : debt.amount;
    final keepOrSetNote = debt.note.trim().isEmpty && note.isNotEmpty ? note : debt.note;
    if (isIncrease) {
      final nextBal = cur + delta;
      await db.update('debts', {'amount': nextBal, 'note': keepOrSetNote, 'settled': 0, 'updated_at': nowIso}, where: 'id = ?', whereArgs: [id]);
      await db.insert('debt_logs', {'debt_id': id, 'kind': 'add', 'delta': delta, 'balance_after': nextBal, 'note': note, 'created_at': nowIso});
      return 'تمت زيادة ${Fmt.money(delta)} ج — الباقي الآن: ${Fmt.money(nextBal)} ج';
    }
    final diff = cur - delta;
    if (diff.abs() < 0.001) {
      await db.update('debts', {'amount': 0.0, 'last_cleared': cur, 'note': keepOrSetNote, 'settled': 1, 'updated_at': nowIso}, where: 'id = ?', whereArgs: [id]);
      await db.insert('debt_logs', {'debt_id': id, 'kind': 'pay', 'delta': delta, 'balance_after': 0.0, 'note': note.isEmpty ? 'سداد الباقي بالكامل' : note, 'created_at': nowIso});
      return 'تم خصم المبلغ وتصفير حساب ${debt.person}';
    } else if (diff > 0) {
      await db.update('debts', {'amount': diff, 'note': keepOrSetNote, 'settled': 0, 'updated_at': nowIso}, where: 'id = ?', whereArgs: [id]);
      await db.insert('debt_logs', {'debt_id': id, 'kind': 'pay', 'delta': delta, 'balance_after': diff, 'note': note, 'created_at': nowIso});
      return 'تم تنزيل ${Fmt.money(delta)} ج من القديم — الباقي: ${Fmt.money(diff)} ج';
    } else {
      final over = diff.abs();
      final newDir = debt.direction == 'on_me' ? 'for_me' : 'on_me';
      final lbl = newDir == 'on_me' ? 'عليا ليه' : 'ليا عنده';
      await db.update('debts', {'amount': over, 'direction': newDir, 'note': keepOrSetNote, 'settled': 0, 'updated_at': nowIso}, where: 'id = ?', whereArgs: [id]);
      await db.insert('debt_logs', {'debt_id': id, 'kind': 'pay', 'delta': delta, 'balance_after': over, 'note': '${note.isNotEmpty ? "$note - " : ""}انقلب الرصيد إلى $lbl', 'created_at': nowIso});
      return 'تم الخصم وتحويل الزيادة إلى ($lbl: ${Fmt.money(over)} ج)';
    }
  }

  Future<String> toggleSettleFull(DebtAccount debt) async {
    final db = await database;
    final id = debt.id!;
    final nowIso = DateTime.now().toIso8601String();
    if (!debt.settled) {
      await db.update('debts', {'amount': 0.0, 'last_cleared': debt.amount, 'settled': 1, 'updated_at': nowIso}, where: 'id = ?', whereArgs: [id]);
      await db.insert('debt_logs', {'debt_id': id, 'kind': 'settle', 'delta': debt.amount, 'balance_after': 0.0, 'note': 'سداد الحساب بالكامل', 'created_at': nowIso});
      return 'تم تصفير حساب ${debt.person}';
    } else {
      final restored = debt.lastClearedAmount > 0 ? debt.lastClearedAmount : 0.0;
      await db.update('debts', {'amount': restored, 'settled': 0, 'updated_at': nowIso}, where: 'id = ?', whereArgs: [id]);
      await db.insert('debt_logs', {'debt_id': id, 'kind': 'reopen', 'delta': restored, 'balance_after': restored, 'note': 'إرجاع الرصيد', 'created_at': nowIso});
      return 'تم إرجاع حساب ${debt.person} لغير خالص';
    }
  }

  Future<void> deleteDebt(int id) async {
    final db = await database;
    await db.delete('debt_logs', where: 'debt_id = ?', whereArgs: [id]);
    await db.delete('debts', where: 'id = ?', whereArgs: [id]);
  }
}

class Fmt {
  static const _m = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
  static const _w = ['الإثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];
  static String toDateKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static String toMonthKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';
  static DateTime parseDateKey(String k) {
    final s = k.split('-');
    return s.length == 3 ? DateTime(int.tryParse(s[0]) ?? 2026, int.tryParse(s[1]) ?? 1, int.tryParse(s[2]) ?? 1) : DateTime.now();
  }
  static bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
  static String dayTitle(DateTime d) {
    final now = DateTime.now();
    if (sameDay(d, now)) return 'اليوم - ${_w[d.weekday - 1]} ${d.day} ${_m[d.month - 1]}';
    return '${_w[d.weekday - 1]} ${d.day} ${_m[d.month - 1]} ${d.year}';
  }
  static String shortDate(DateTime d) => '${_w[d.weekday - 1]} ${d.day} ${_m[d.month - 1]}';
  static String monthTitle(DateTime d) => '${_m[d.month - 1]} ${d.year}';
  static String time12h(DateTime d) => '${d.hour % 12 == 0 ? 12 : d.hour % 12}:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? "م" : "ص"}';
  static String money(double v) {
    final abs = v.abs();
    final raw = (abs - abs.roundToDouble()).abs() < 0.001 ? abs.round().toString() : abs.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    final parts = raw.split('.');
    final ip = parts[0].replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    return parts.length > 1 ? '$ip.${parts[1]}' : ip;
  }
  static double? parseNum(String raw) {
    const east = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    var s = raw.trim().replaceAll(',', '');
    for (var i = 0; i < east.length; i++) {
      s = s.replaceAll(east[i], i.toString());
    }
    s = s.replaceAll('٫', '.');
    return s.isEmpty ? null : double.tryParse(s);
  }
}

class CashHomeScreen extends StatefulWidget {
  const CashHomeScreen({super.key, this.testDaily, this.testDebts});
  final List<CashTransaction>? testDaily;
  final List<DebtAccount>? testDebts;
  @override
  State<CashHomeScreen> createState() => _CashHomeScreenState();
}

class _CashHomeScreenState extends State<CashHomeScreen> {
  int _tab = 0;
  TxType _type = TxType.deposit;
  DateTime _date = DateTime.now();
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  final _amtCtrl = TextEditingController(), _profCtrl = TextEditingController();
  final _personCtrl = TextEditingController(), _debtAmtCtrl = TextEditingController(), _debtNoteCtrl = TextEditingController();
  String _debtDir = 'for_me', _debtFilter = 'unpaid', _debtSearch = '';
  final Set<int> _expanded = {};
  List<CashTransaction> _daily = [];
  List<DebtAccount> _debts = [];
  List<DailySummaryRow> _monthly = [];

  @override
  void initState() {
    super.initState();
    if (widget.testDaily != null || widget.testDebts != null) {
      _daily = List<CashTransaction>.from(widget.testDaily ?? const []);
      _debts = List<DebtAccount>.from(widget.testDebts ?? const []);
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final d = await CashDatabase.instance.getTxForDate(Fmt.toDateKey(_date));
    final db = await CashDatabase.instance.getAllDebts();
    final m = await CashDatabase.instance.getMonthly(Fmt.toMonthKey(_month));
    if (!mounted) return;
    setState(() {
      _daily = d;
      _debts = db;
      _monthly = m;
    });
  }

  void _msg(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 2), behavior: SnackBarBehavior.floating));
  }

  String _buildStatement(DebtAccount d) {
    final b = StringBuffer();
    b.writeln('📋 *كشف حساب - دفتر الكاش*');
    b.writeln('العميل: ${d.person}');
    if (d.note.trim().isNotEmpty) {
      b.writeln('ملاحظة: ${d.note.trim()}');
    }
    b.writeln('━━━━━━━━━━━━━━');
    if (d.logs.isNotEmpty) {
      b.writeln('📌 *سجل الحركات:*');
      for (final ev in d.logs.reversed) {
        final lbl = ev.kind == 'pay'
            ? 'تم سداد (-)'
            : (ev.kind == 'add'
                ? 'إضافة (+)'
                : (ev.kind == 'settle' ? 'تصفير الحساب (-)' : (ev.kind == 'reopen' ? 'إرجاع رصيد (+)' : 'بداية الحساب')));
        final n = ev.note.isNotEmpty ? ' (${ev.note})' : '';
        b.writeln('• $lbl: ${Fmt.money(ev.delta)} ج ← الباقي: ${Fmt.money(ev.balanceAfter)} ج$n (${Fmt.shortDate(ev.createdAt)})');
      }
      b.writeln('━━━━━━━━━━━━━━');
    }
    if (d.settled) {
      b.write('✅ *الحساب خالص بالكامل (الباقي: 0 ج.م)*');
    } else if (d.isForMe) {
      b.write('💰 *المبلغ المتبقي للسداد: ${Fmt.money(d.amount)} ج.م*');
    } else {
      b.write('💰 *الرصيد المتبقي ليك: ${Fmt.money(d.amount)} ج.م*');
    }
    return b.toString();
  }

  String _extractPhone(String raw) {
    const east = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    var s = raw;
    for (var i = 0; i < east.length; i++) {
      s = s.replaceAll(east[i], i.toString());
    }
    final m = RegExp(r'(?:\+?20|0)(1[0125]\d{8})').firstMatch(s.replaceAll(' ', '').replaceAll('-', ''));
    return m != null ? '20${m.group(1)}' : '';
  }

  Future<void> _copyStatement(DebtAccount d) async {
    await Clipboard.setData(ClipboardData(text: _buildStatement(d)));
    _msg('تم نسخ كشف حساب ${d.person}');
  }

  Future<void> _shareExternal(DebtAccount d) async {
    final text = _buildStatement(d);
    await Clipboard.setData(ClipboardData(text: text));
    final phone = _extractPhone('${d.person} ${d.note}');
    final uri = Uri(
      scheme: 'https',
      host: 'wa.me',
      path: phone.isNotEmpty ? '/$phone' : '/',
      query: 'text=${Uri.encodeComponent(text)}',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _addTx() async {
    final a = Fmt.parseNum(_amtCtrl.text);
    final pr = _profCtrl.text.trim().isEmpty ? 0.0 : Fmt.parseNum(_profCtrl.text);
    if (a == null || a <= 0 || pr == null || pr < 0) return _msg('اكتب المبلغ والمكسب بشكل صحيح');
    final now = DateTime.now();
    final dt = Fmt.sameDay(_date, now) ? now : DateTime(_date.year, _date.month, _date.day, now.hour, now.minute);
    await CashDatabase.instance.insertTx(CashTransaction(type: _type, amount: a, profit: pr, createdAt: dt));
    HapticFeedback.lightImpact();
    _amtCtrl.clear();
    _profCtrl.clear();
    _month = DateTime(_date.year, _date.month);
    await _load();
  }

  Future<void> _addDebt() async {
    final name = _personCtrl.text.trim();
    final a = Fmt.parseNum(_debtAmtCtrl.text);
    if (name.isEmpty || a == null || a <= 0) return _msg('اكتب اسم العميل والمبلغ');
    final res = await CashDatabase.instance.addOrMergeDebt(name, a, _debtDir, _debtNoteCtrl.text.trim());
    _personCtrl.clear();
    _debtAmtCtrl.clear();
    _debtNoteCtrl.clear();
    if (_debtFilter == 'settled') _debtFilter = 'unpaid';
    await _load();
    _msg(res);
  }

  Future<void> _openAdjustSheet(DebtAccount debt, bool initialInc) async {
    var inc = debt.settled ? true : initialInc;
    final cAmt = TextEditingController(), cNote = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setM) {
        final cur = debt.settled ? 0.0 : debt.amount;
        final val = Fmt.parseNum(cAmt.text);
        var prev = 'الرصيد القديم: ${Fmt.money(cur)} ج';
        if (val != null && val > 0) {
          prev = inc ? 'الرصيد بعد الزيادة: ${Fmt.money(cur + val)} ج' : 'الباقي بعد الخصم من القديم: ${Fmt.money((cur - val).clamp(0, double.infinity))} ج';
        }
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('تعديل حساب: ${debt.person}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: ChoiceChip(label: const Text('سداد جزء (-)'), selected: !inc, onSelected: debt.settled ? null : (_) => setM(() => inc = false))),
                  const SizedBox(width: 8),
                  Expanded(child: ChoiceChip(label: const Text('زيادة مبلغ (+)'), selected: inc, onSelected: (_) => setM(() => inc = true))),
                ]),
                const SizedBox(height: 10),
                TextField(controller: cAmt, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setM(() {}), decoration: InputDecoration(labelText: inc ? 'المبلغ المضاف' : 'المبلغ المسدّد من القديم', suffixText: 'ج')),
                const SizedBox(height: 8),
                TextField(controller: cNote, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)')),
                const SizedBox(height: 10),
                Text(prev, style: const TextStyle(color: Color(0xFF0F766E), fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: () async {
                    final v = Fmt.parseNum(cAmt.text);
                    if (v == null || v <= 0) return;
                    Navigator.of(ctx).pop();
                    final r = await CashDatabase.instance.adjustDebt(debt, inc, v, cNote.text.trim());
                    if (debt.id != null) _expanded.add(debt.id!);
                    await _load();
                    _msg(r);
                  },
                  child: const Text('حفظ التعديل'),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['دفتر الكاش', 'سجل الآجل والديون', 'جرد الأرباح الشهري'];
    return Scaffold(
      appBar: AppBar(backgroundColor: const Color(0xFF0F766E), foregroundColor: Colors.white, title: Text(titles[_tab], style: const TextStyle(fontWeight: FontWeight.bold))),
      body: IndexedStack(index: _tab, children: [_buildDaily(), _buildDebts(), _buildMonthly()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bolt_rounded), label: 'معاملات اليوم'),
          NavigationDestination(icon: Icon(Icons.people_alt_rounded), label: 'الآجل والديون'),
          NavigationDestination(icon: Icon(Icons.assessment_rounded), label: 'جرد الشهر'),
        ],
      ),
    );
  }

  Widget _heroBox(String label, String value, {Color valColor = Colors.white}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(30),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(value, style: TextStyle(color: valColor, fontSize: 15, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildDaily() {
    double gain = 0, vol = 0, depVol = 0, witVol = 0;
    int depCount = 0, witCount = 0;
    for (final t in _daily) {
      vol += t.amount;
      gain += t.profit;
      if (t.type == TxType.withdraw) {
        witVol += t.amount;
        witCount++;
      } else {
        depVol += t.amount;
        depCount++;
      }
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFF0F766E), borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              IconButton(onPressed: () { setState(() => _date = _date.subtract(const Duration(days: 1))); _load(); }, icon: const Icon(Icons.chevron_right, color: Colors.white)),
              Text(Fmt.dayTitle(_date), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              IconButton(onPressed: () { setState(() => _date = _date.add(const Duration(days: 1))); _load(); }, icon: const Icon(Icons.chevron_left, color: Colors.white)),
            ]),
            Row(children: [
              _heroBox('ربح اليوم', '+${Fmt.money(gain)} ج', valColor: const Color(0xFF86EFAC)),
              const SizedBox(width: 8),
              _heroBox('حركة الكاش (${_daily.length})', '${Fmt.money(vol)} ج'),
            ]),
            const SizedBox(height: 7),
            Row(children: [
              _heroBox('مجموع الإيداع ($depCount)', '${Fmt.money(depVol)} ج'),
              const SizedBox(width: 8),
              _heroBox('مجموع السحب ($witCount)', '${Fmt.money(witVol)} ج'),
            ]),
          ]),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            Row(children: TxType.values.map((t) => Expanded(child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(label: SizedBox(width: double.infinity, child: Text(t.label, textAlign: TextAlign.center)), selected: _type == t, onSelected: (_) => setState(() => _type = t)),
            ))).toList()),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: _amtCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'المبلغ (${_type.label})', suffixText: 'ج'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _profCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), onSubmitted: (_) => _addTx(), decoration: const InputDecoration(labelText: 'المكسب', suffixText: 'ج'))),
              const SizedBox(width: 8),
              FilledButton(style: FilledButton.styleFrom(backgroundColor: _type.color), onPressed: _addTx, child: const Text('إضافة')),
            ]),
          ]),
        ),
        const SizedBox(height: 10),
        ..._daily.map((tx) => Card(
          child: ListTile(
            leading: Icon(tx.type.icon, color: tx.type.color),
            title: Text('${tx.type.label} • ${Fmt.money(tx.amount)} ج', style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(Fmt.time12h(tx.createdAt)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('+${Fmt.money(tx.profit)} ج', style: const TextStyle(color: Color(0xFF15803D), fontWeight: FontWeight.bold)),
              IconButton(icon: const Icon(Icons.delete_outline, size: 20), onPressed: () async { if (tx.id != null) { await CashDatabase.instance.deleteTx(tx.id!); _load(); } }),
            ]),
          ),
        )),
      ],
    );
  }

  Widget _buildDebts() {
    double forMe = 0, onMe = 0;
    for (final d in _debts) {
      if (!d.settled) {
        if (d.isForMe) { forMe += d.amount; } else { onMe += d.amount; }
      }
    }
    final q = _debtSearch.trim().toLowerCase();
    final list = _debts.where((d) {
      if (q.isNotEmpty && !('${d.person} ${d.note}').toLowerCase().contains(q)) return false;
      if (_debtFilter == 'unpaid') return !d.settled;
      if (_debtFilter == 'settled') return d.settled;
      return true;
    }).toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(children: [
          Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [const Text('فلوس ليا بره'), Text('${Fmt.money(forMe)} ج', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF15803D)))])))),
          Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [const Text('فلوس عليا'), Text('${Fmt.money(onMe)} ج', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFFB91C1C)))])))),
        ]),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Row(children: [
                Expanded(child: ChoiceChip(label: const Text('ليا عنده'), selected: _debtDir == 'for_me', onSelected: (_) => setState(() => _debtDir = 'for_me'))),
                const SizedBox(width: 8),
                Expanded(child: ChoiceChip(label: const Text('عليا ليه'), selected: _debtDir == 'on_me', onSelected: (_) => setState(() => _debtDir = 'on_me'))),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: _personCtrl, decoration: const InputDecoration(labelText: 'اسم العميل'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: _debtAmtCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'المبلغ', suffixText: 'ج'))),
                const SizedBox(width: 8),
                FilledButton(onPressed: _addDebt, child: const Text('إضافة')),
              ]),
              const SizedBox(height: 8),
              TextField(controller: _debtNoteCtrl, onSubmitted: (_) => _addDebt(), decoration: const InputDecoration(labelText: 'رقم التليفون أو ملاحظة (اختياري)')),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        TextField(onChanged: (v) => setState(() => _debtSearch = v), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'بحث باسم العميل أو الملاحظة...')),
        const SizedBox(height: 8),
        Row(children: [
          for (final f in [('unpaid', 'غير خالص'), ('settled', 'خالص'), ('all', 'الكل')])
            Padding(padding: const EdgeInsets.only(left: 6), child: ChoiceChip(label: Text(f.$2), selected: _debtFilter == f.$1, onSelected: (_) => setState(() => _debtFilter = f.$1))),
        ]),
        const SizedBox(height: 8),
        ...list.map((d) {
          final id = d.id ?? 0;
          final exp = _expanded.contains(id);
          final cleanNote = d.note.trim();
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('${d.person} (${d.isForMe ? "ليا عنده" : "عليا ليه"})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () => _shareExternal(d),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(color: const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0xFF86EFAC))),
                            child: const Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.send_rounded, size: 13, color: Color(0xFF15803D)),
                              SizedBox(width: 4),
                              Text('مشاركة الكشف', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF15803D))),
                            ]),
                          ),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () => _copyStatement(d),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(999)),
                            child: const Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.copy_rounded, size: 13, color: Color(0xFF334155)),
                              SizedBox(width: 3),
                              Text('نسخ', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
                            ]),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(d.settled ? '0 ج (خالص)' : 'الباقي: ${Fmt.money(d.amount)} ج', style: TextStyle(fontWeight: FontWeight.bold, color: d.isForMe ? const Color(0xFF15803D) : const Color(0xFFB91C1C))),
                  IconButton(icon: const Icon(Icons.delete_outline, size: 20), onPressed: () async { await CashDatabase.instance.deleteDebt(id); _load(); }),
                ]),
                if (cleanNote.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.notes_rounded, size: 15, color: Color(0xFF0F766E)),
                      const SizedBox(width: 6),
                      Expanded(child: Text('ملاحظة: $cleanNote', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF334155)))),
                    ]),
                  ),
                const SizedBox(height: 6),
                Wrap(spacing: 6, children: [
                  if (!d.settled) OutlinedButton(onPressed: () => _openAdjustSheet(d, false), child: const Text('- سداد جزء')),
                  OutlinedButton(onPressed: () => _openAdjustSheet(d, true), child: const Text('+ زوّد مبلغ')),
                  TextButton(onPressed: () async { final r = await CashDatabase.instance.toggleSettleFull(d); await _load(); _msg(r); }, child: Text(d.settled ? 'إرجاع' : 'تسديد الكل ✓')),
                  TextButton(onPressed: () => setState(() => exp ? _expanded.remove(id) : _expanded.add(id)), child: Text('الحركات (${d.logs.length})')),
                ]),
                if (exp) ...d.logs.map((ev) {
                  final evNote = ev.note.trim().isNotEmpty ? ' • (${ev.note.trim()})' : '';
                  final kindTxt = ev.kind == 'pay' ? 'سدد جزء (-)' : (ev.kind == 'add' ? 'زيادة (+)' : (ev.kind == 'settle' ? 'تصفير (-)' : (ev.kind == 'reopen' ? 'إرجاع (+)' : 'بداية الحساب')));
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('$kindTxt: ${Fmt.money(ev.delta)} ج  ←  الباقي: ${Fmt.money(ev.balanceAfter)} ج$evNote (${Fmt.shortDate(ev.createdAt)})', style: const TextStyle(fontSize: 12)),
                  );
                }),
              ]),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildMonthly() {
    double gain = 0, vol = 0, dep = 0, wit = 0;
    for (final r in _monthly) { gain += r.totalGain; vol += r.totalVolume; dep += r.depositVolume; wit += r.withdrawVolume; }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          IconButton(onPressed: () { setState(() => _month = DateTime(_month.year, _month.month - 1)); _load(); }, icon: const Icon(Icons.chevron_right)),
          Text(Fmt.monthTitle(_month), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          IconButton(onPressed: () { setState(() => _month = DateTime(_month.year, _month.month + 1)); _load(); }, icon: const Icon(Icons.chevron_left)),
        ]),
        Card(color: const Color(0xFF0F766E), child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('إجمالي مكسب الشهر', style: TextStyle(color: Colors.white70)),
          Text('+${Fmt.money(gain)} ج.م', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 26)),
          Text('حركة الكاش: ${Fmt.money(vol)} ج  •  إيداع: ${Fmt.money(dep)} ج  •  سحب: ${Fmt.money(wit)} ج', style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ]))),
        const SizedBox(height: 8),
        ..._monthly.map((r) => Card(child: ListTile(
          onTap: () { setState(() { _date = Fmt.parseDateKey(r.dateKey); _tab = 0; }); _load(); },
          title: Text(Fmt.shortDate(Fmt.parseDateKey(r.dateKey)), style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('${r.txCount} عملية • حركة: ${Fmt.money(r.totalVolume)} ج'),
          trailing: Text('+${Fmt.money(r.totalGain)} ج', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF15803D))),
        ))),
      ],
    );
  }
}
