import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:daftar_el_cash/main.dart';

void main() {
  testWidgets('Daily totals, debt notes, JSON backup, and automatic AccessibilityService frame extractor work accurately', (WidgetTester tester) async {
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

    // 2. Test Automatic AccessibilityService Frame Extractor across multi-day scrolling & debts
    final simulatedFrames = jsonEncode([
      {
        'nodes': [
          {'t': 'اليوم - الإثنين 16 نوفمبر', 'x': 540, 'y': 220, 'top': 200, 'bot': 240},
          {'t': 'إيداع • 3,000 ج\n2:15 م\n+30 ج', 'x': 540, 'y': 620, 'top': 590, 'bot': 650},
          {'t': 'سحب • 1,200 ج', 'x': 800, 'y': 760, 'top': 730, 'bot': 790},
          {'t': '4:40 م', 'x': 800, 'y': 785, 'top': 770, 'bot': 800},
          {'t': '+12 ج', 'x': 220, 'y': 760, 'top': 740, 'bot': 780},
        ]
      },
      {
        'nodes': [
          {'t': 'الأحد 15 نوفمبر 2026', 'x': 540, 'y': 220, 'top': 200, 'bot': 240},
          {'t': 'إيداع • 5,000 ج\n11:10 ص\n+50 ج', 'x': 540, 'y': 620, 'top': 590, 'bot': 650},
        ]
      },
      {
        'nodes': [
          {'t': 'مصطفى كامل (ليا عنده)', 'x': 780, 'y': 500, 'top': 480, 'bot': 520},
          {'t': 'الباقي: 850 ج', 'x': 240, 'y': 500, 'top': 480, 'bot': 520},
          {'t': 'بداية الحساب: 1,000 ج  ←  الباقي: 1,000 ج • (01011223344 باقي شحن) (السبت 14 نوفمبر)', 'x': 540, 'y': 590, 'top': 575, 'bot': 605},
          {'t': 'سدد جزء (-): 150 ج  ←  الباقي: 850 ج • (كاش) (الأحد 15 نوفمبر)', 'x': 540, 'y': 630, 'top': 615, 'bot': 645},
          {'t': 'ياسر جلال (عليا ليه)', 'x': 780, 'y': 760, 'top': 740, 'bot': 780},
          {'t': 'الباقي: 400 ج', 'x': 240, 'y': 760, 'top': 740, 'bot': 780},
        ]
      }
    ]);

    final autoExtracted = BackupPayload.decodeExtractedFrames(simulatedFrames, nowOverride: now);
    expect(autoExtracted.transactions.length, 3);
    expect(autoExtracted.transactions.any((t) => t.amount == 5000 && t.createdAt.day == 15), true);
    expect(autoExtracted.debts.length, 2);
    expect(autoExtracted.debts[0].person, 'مصطفى كامل');
    expect(autoExtracted.debts[0].amount, 850);
    expect(autoExtracted.debts[0].note, '01011223344 باقي شحن');
    expect(autoExtracted.debts[0].logs.length, 2);
    expect(autoExtracted.debts[1].person, 'ياسر جلال');
    expect(autoExtracted.debts[1].isForMe, false);
    expect(autoExtracted.debts[1].amount, 400);

    await tester.pumpWidget(CashOfficeApp(testDaily: txs, testDebts: debts));
    await tester.pumpAndSettle();

    expect(find.text('+23 ج'), findsOneWidget);
    expect(find.text('مجموع الإيداع (2)'), findsOneWidget);
    expect(find.text('مجموع السحب (1)'), findsOneWidget);

    await tester.tap(find.text('نسخة احتياطية'));
    await tester.pumpAndSettle();
    expect(find.text('اسحب كل بيانات النسخة القديمة تلقائياً الآن'), findsOneWidget);
  });
}
