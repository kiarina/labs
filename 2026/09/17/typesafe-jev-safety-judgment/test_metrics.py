"""Unit tests for metrics.py, checked against hand-computed values."""

import math
import unittest

import metrics


class TestMetrics(unittest.TestCase):
    def test_precision_recall_f1(self):
        labels = [True, True, False, False]
        preds = [True, False, True, False]
        r = metrics.precision_recall_f1(labels, preds)
        self.assertEqual((r["tp"], r["fp"], r["fn"], r["tn"]), (1, 1, 1, 1))
        self.assertAlmostEqual(r["precision"], 0.5)
        self.assertAlmostEqual(r["recall"], 0.5)
        self.assertAlmostEqual(r["f1"], 0.5)

    def test_precision_recall_empty_positive(self):
        r = metrics.precision_recall_f1([False, False], [False, False])
        self.assertEqual(r["precision"], 0.0)
        self.assertEqual(r["recall"], 0.0)

    def test_average_precision_perfect(self):
        labels = [True, True, False, False]
        scores = [0.9, 0.8, 0.2, 0.1]
        self.assertAlmostEqual(metrics.average_precision(labels, scores), 1.0)

    def test_average_precision_known(self):
        # ranking: 0.9(pos) 0.6(neg) 0.5(pos) 0.1(neg)
        labels = [True, False, True, False]
        scores = [0.9, 0.6, 0.5, 0.1]
        # AP = 1.0*(0.5) + (2/3)*(0.5) = 0.8333...
        self.assertAlmostEqual(metrics.average_precision(labels, scores), 0.5 + (2 / 3) * 0.5)

    def test_average_precision_no_positive(self):
        self.assertTrue(math.isnan(metrics.average_precision([False, False], [0.1, 0.2])))

    def test_roc_auc_perfect(self):
        labels = [True, True, False, False]
        scores = [0.9, 0.8, 0.2, 0.1]
        self.assertAlmostEqual(metrics.roc_auc(labels, scores), 1.0)

    def test_roc_auc_half(self):
        # all equal scores -> ties -> AUC 0.5
        labels = [True, False, True, False]
        scores = [0.5, 0.5, 0.5, 0.5]
        self.assertAlmostEqual(metrics.roc_auc(labels, scores), 0.5)

    def test_roc_auc_known(self):
        labels = [True, False, True, False]
        scores = [0.8, 0.6, 0.4, 0.2]
        # pos ranks (sorted asc: 0.2,0.4,0.6,0.8 -> ranks 1,2,3,4);
        # pos=0.8(rank4),0.4(rank2); rank_sum=6; auc=(6-3)/(2*2)=0.75
        self.assertAlmostEqual(metrics.roc_auc(labels, scores), 0.75)

    def test_ece_perfect_calibration(self):
        # two bins, confidence == accuracy in each
        labels = [False, False, True, True]
        scores = [0.0, 0.0, 1.0, 1.0]
        r = metrics.expected_calibration_error(labels, scores, bins=10)
        self.assertAlmostEqual(r["ece"], 0.0)

    def test_ece_miscalibrated(self):
        # all scored 0.9 but only half are positive -> ECE = 0.4
        labels = [True, False, True, False]
        scores = [0.9, 0.9, 0.9, 0.9]
        r = metrics.expected_calibration_error(labels, scores, bins=10)
        self.assertAlmostEqual(r["ece"], 0.4)

    def test_automation_coverage(self):
        labels = [True, True, False, False]
        scores = [0.95, 0.5, 0.5, 0.05]
        r = metrics.automation_coverage(labels, scores, low=0.2, high=0.8)
        # auto_pos: idx0 (correct). auto_neg: idx3 (correct). review: idx1, idx2
        self.assertAlmostEqual(r["auto_fraction"], 0.5)
        self.assertAlmostEqual(r["review_fraction"], 0.5)
        self.assertEqual(r["auto_error_rate"], 0.0)
        self.assertEqual(r["auto_missed_positives"], 0)

    def test_automation_coverage_missed(self):
        labels = [True, False]
        scores = [0.1, 0.05]  # both auto-negative; idx0 is a missed positive
        r = metrics.automation_coverage(labels, scores, low=0.2, high=0.8)
        self.assertEqual(r["auto_missed_positives"], 1)
        self.assertAlmostEqual(r["auto_error_rate"], 0.5)

    def test_threshold_preds(self):
        self.assertEqual(metrics.threshold_preds([0.4, 0.5, 0.6], 0.5), [False, True, True])


if __name__ == "__main__":
    unittest.main()
