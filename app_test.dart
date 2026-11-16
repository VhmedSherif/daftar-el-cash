import 'package:flutter_test/flutter_test.dart';
import 'package:daftar_el_cash/main.dart';

void main() {
  testWidgets('Daily totals, debt notes, JSON backup, and smart legacy import work accurately', (WidgetTester tester) async {
    final now = DateTime(2026, 11, 16, 12, 0);
    final txs = [
      CashTransaction(id: 1, type: TxType.deposit, amount: 1000, profit: 10, createdAt: now),
      CashTransaction(id: 2, type: TxType.deposit, amount: 500, profit: 5, createdAt: now),
      CashTransaction(id: 3, type: TxType.withdraw, amount: 400, profit: 8, createdAt: now),
    ];
    final debts = [
      DebtAccount(
        id: 1,
        person: 'أحمد محمود',
        amount: 600,
        lastClearedAmount: 0,
        direction: 'for_me',
        note: '01012345678 باقي تحويل',
        settled: false,
        logs: [
          DebtLogEntry(
            debtId: 1,
            kind: 'pay',
            delta: 400,
            balanceAfter: 600,
            note: 'سداد فودافون كاش',
            createdAt: now,
          ),
        ],
      ),
    ];

    // 1. Test lossless JSON backup encode/decode round-trip
    final encoded = BackupPayload.encode(transactions: txs, debts: debts);
    final decoded = BackupPayload.decode(encoded);
    expect(decoded.transactions.length, 3);
    expect(decoded.debts.length, 1);
    expect(decoded.debts.first.note, '01012345678 باقي تحويل');
    expect(decoded.debts.first.logs.first.note, 'سداد فودافون كاش');

    // 2. Test Smart Bulk WhatsApp Statements Import
    const bulkStatements = '''
📋 *كشف حساب - دفتر الكاش*
العميل: كريم عادل
ملاحظة: 01099887766
━━━━━━━━━━━━━━
📌 *سجل الحركات:*
• بداية الحساب: 1,200 ج ← الباقي: 1,200 ج (السبت 14 نوفمبر)
• تم سداد (-): 500 ج ← الباقي: 700 ج (كاش) (الأحد 15 نوفمبر)
━━━━━━━━━━━━━━
💰 *المبلغ المتبقي للسداد: 700 ج.م*
📋 *كشف حساب - دفتر الكاش*
العميل: طارق حسن
━━━━━━━━━━━━━━
💰 *الرصيد المتبقي ليك: 350 ج.م*
''';
    final parsedStmts = BackupPayload.decode(bulkStatements, fallbackDate: now);
    expect(parsedStmts.debts.length, 2);
    expect(parsedStmts.debts[0].person, 'كريم عادل');
    expect(parsedStmts.debts[0].amount, 700);
    expect(parsedStmts.debts[0].isForMe, true);
    expect(parsedStmts.debts[0].logs.length, 2);
    expect(parsedStmts.debts[1].person, 'طارق حسن');
    expect(parsedStmts.debts[1].amount, 350);
    expect(parsedStmts.debts[1].isForMe, false);

    // 3. Test Smart Screenshot OCR Text Import (Old App UI cards)
    const ocrScreenText = '''
إيداع • 2,500 ج
3:30 م
+25 ج
سحب • 800 ج
4:15 م
+10 ج
محمود سمير (ليا عنده)
الباقي: 1,450 ج
ملاحظة: فودافون
الباقي: 300 ج سامح رجب (عليا ليه)
''';
    final parsedOcr = BackupPayload.decode(ocrScreenText, fallbackDate: now);
    expect(parsedOcr.transactions.length, 2);
    expect(parsedOcr.transactions[0].amount, 2500);
    expect(parsedOcr.transactions[0].profit, 25);
    expect(parsedOcr.transactions[1].type, TxType.withdraw);
    expect(parsedOcr.debts.length, 2);
    expect(parsedOcr.debts[0].person, 'محمود سمير');
    expect(parsedOcr.debts[0].amount, 1450);
    expect(parsedOcr.debts[0].note, 'فودافون');
    expect(parsedOcr.debts[1].person, 'سامح رجب');
    expect(parsedOcr.debts[1].amount, 300);
    expect(parsedOcr.debts[1].isForMe, false);

    await tester.pumpWidget(CashOfficeApp(testDaily: txs, testDebts: debts));
    await tester.pumpAndSettle();

    expect(find.text('+23 ج'), findsOneWidget);
    expect(find.text('حركة الكاش (3)'), findsOneWidget);
    expect(find.text('1,900 ج'), findsOneWidget);
    expect(find.text('مجموع الإيداع (2)'), findsOneWidget);
    expect(find.text('1,500 ج'), findsOneWidget);
    expect(find.text('مجموع السحب (1)'), findsOneWidget);
    expect(find.text('400 ج'), findsOneWidget);

    await tester.tap(find.text('الآجل والديون'));
    await tester.pumpAndSettle();
    expect(find.text('ملاحظة: 01012345678 باقي تحويل'), findsOneWidget);

    await tester.tap(find.text('نسخة احتياطية'));
    await tester.pumpAndSettle();
    expect(find.text('أخذ نسخة احتياطية لكل البيانات'), findsOneWidget);
    expect(find.text('نقل واسترجاع البيانات (ذكي وسريع)'), findsOneWidget);
  });
}
