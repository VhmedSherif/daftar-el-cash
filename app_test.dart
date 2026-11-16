import 'package:flutter_test/flutter_test.dart';
import 'package:daftar_el_cash/main.dart';

void main() {
  testWidgets('Daily totals, debt notes, and backup codec work accurately', (WidgetTester tester) async {
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

    // Test lossless JSON backup encode/decode round-trip
    final encoded = BackupPayload.encode(transactions: txs, debts: debts);
    final decoded = BackupPayload.decode(encoded);
    expect(decoded.transactions.length, 3);
    expect(decoded.debts.length, 1);
    expect(decoded.debts.first.note, '01012345678 باقي تحويل');
    expect(decoded.debts.first.logs.first.note, 'سداد فودافون كاش');

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
  });
}
