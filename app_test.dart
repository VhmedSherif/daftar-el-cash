import 'package:flutter_test/flutter_test.dart';
import 'package:daftar_el_cash/main.dart';

void main() {
  testWidgets('Daily totals and debt notes render accurately', (WidgetTester tester) async {
    final now = DateTime(2026, 11, 16, 12, 0);
    await tester.pumpWidget(
      CashOfficeApp(
        testDaily: [
          CashTransaction(id: 1, type: TxType.deposit, amount: 1000, profit: 10, createdAt: now),
          CashTransaction(id: 2, type: TxType.deposit, amount: 500, profit: 5, createdAt: now),
          CashTransaction(id: 3, type: TxType.withdraw, amount: 400, profit: 8, createdAt: now),
        ],
        testDebts: [
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
        ],
      ),
    );
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

    await tester.tap(find.text('الحركات (1)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('سداد فودافون كاش'), findsOneWidget);
  });
}
