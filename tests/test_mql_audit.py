"""Portable checks of shipped expressions; not a replacement for MetaEditor."""
import re
import unittest
from pathlib import Path

SOURCE = Path('/mnt/documents/ScalpWIN_Pro_Painel_v2.6.mq5').read_text()


class AuditChecks(unittest.TestCase):
    def test_buy_adverse_execution(self):
        expression = re.search(r'\?\(price-a\)/g_point', SOURCE).group()[1:]
        self.assertEqual(eval(expression, {}, dict(price=125010, a=125000, g_point=1)), 10)

    def test_sell_adverse_execution(self):
        expression = re.search(r':\(b-price\)/g_point', SOURCE).group()[1:]
        self.assertEqual(eval(expression, {}, dict(price=124990, b=125000, g_point=1)), 10)

    def test_deal_net_includes_entry_costs_and_fees(self):
        expression = re.search(r'AuditNum\((profit\+commission\+swap\+fee)\)', SOURCE).group(1)
        self.assertEqual(eval(expression, {}, dict(profit=100, commission=-5, swap=-2, fee=-3)), 90)

    def test_trailing_thirty_percent_of_peak(self):
        expression = re.search(r'\? (maxDailyAccum \* \(1.0 - InpTrailingMetaPct / 100.0\))', SOURCE).group(1)
        self.assertEqual(eval(expression, {}, dict(maxDailyAccum=500, InpTrailingMetaPct=30)), 350)
        self.assertEqual(eval(expression, {}, dict(maxDailyAccum=800, InpTrailingMetaPct=30)), 560)

    def test_trailing_is_still_gated_by_target(self):
        self.assertIn('if(dailyPL >= InpMaxDailyProfit) targetHit = true;', SOURCE)
        self.assertIn('(targetHit && dailyPL <= metaFloor)', SOURCE)
        for name, value in [('InpMaxDailyProfit', '500.0'), ('InpMaxDailyLoss', '1000.0')]:
            actual = re.search(r'input double\s+' + name + r'\s*=\s*([\d.]+)', SOURCE).group(1)
            self.assertEqual(float(actual), float(value))

    def test_transaction_callback_has_no_disk_or_history_reads(self):
        body = re.search(r'void OnTradeTransaction[^\{]+\{([^}]+)\}', SOURCE).group(1)
        self.assertIn('AuditQueue(trans.deal)', body)
        self.assertNotIn('File', body)
        self.assertNotIn('History', body)

    def test_balanced_braces_and_csv_schema(self):
        stripped = re.sub(r'//[^\n]*|"(?:\\.|[^"\\])*"', '', SOURCE)
        depth = 0
        for char in stripped:
            depth += (char == '{') - (char == '}')
            self.assertGreaterEqual(depth, 0)
        self.assertEqual(depth, 0)
        header = re.search(r'string header="([^"]+)"', SOURCE).group(1)
        self.assertEqual(len(header.split(';')), 43)
        self.assertEqual(len(header.split(';')), len(set(header.split(';'))))


if __name__ == '__main__':
    unittest.main()