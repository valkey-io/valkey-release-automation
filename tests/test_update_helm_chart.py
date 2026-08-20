import unittest

from scripts.update_helm_chart import update_chart

CHART = """apiVersion: v2
name: valkey
version: 0.11.0
appVersion: "9.1.1"
"""
README = (
    "![Version: 0.11.0](https://img.shields.io/badge/Version-0.11.0-informational) "
    "![AppVersion: 9.1.1](https://img.shields.io/badge/AppVersion-9.1.1-informational)\n"
)


class UpdateHelmChartTest(unittest.TestCase):
    def test_bumps_chart_patch_and_app_version(self) -> None:
        chart, readme, chart_version = update_chart(CHART, README, "9.1.2")
        self.assertEqual(chart_version, "0.11.1")
        self.assertIn("version: 0.11.1", chart)
        self.assertIn('appVersion: "9.1.2"', chart)
        self.assertIn("![Version: 0.11.1]", readme)
        self.assertIn("Version-0.11.1-informational", readme)
        self.assertIn("![AppVersion: 9.1.2]", readme)
        self.assertIn("AppVersion-9.1.2-informational", readme)

    def test_is_idempotent_for_same_version(self) -> None:
        chart, readme, chart_version = update_chart(CHART, README, "9.1.1")
        self.assertEqual((chart, readme, chart_version), (CHART, README, "0.11.0"))

    def test_repairs_stale_badges_without_bumping_chart(self) -> None:
        stale = README.replace("0.11.0", "0.10.9").replace("9.1.1", "9.1.0")
        chart, readme, chart_version = update_chart(CHART, stale, "9.1.1")
        self.assertEqual(chart, CHART)
        self.assertEqual(chart_version, "0.11.0")
        self.assertIn("![Version: 0.11.0]", readme)
        self.assertIn("![AppVersion: 9.1.1]", readme)

    def test_does_not_downgrade_chart(self) -> None:
        chart, readme, chart_version = update_chart(CHART, README, "9.0.9")
        self.assertEqual((chart, readme, chart_version), (CHART, README, "0.11.0"))

    def test_rejects_rc_or_malformed_versions(self) -> None:
        for version in ("9.2.0-rc1", "9.2", "latest"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                update_chart(CHART, README, version)

    def test_rejects_unparseable_chart(self) -> None:
        with self.assertRaisesRegex(ValueError, "could not find"):
            update_chart("name: valkey\n", README, "9.1.2")

    def test_rejects_missing_readme_badges(self) -> None:
        with self.assertRaisesRegex(ValueError, "badges"):
            update_chart(CHART, "# Valkey\n", "9.1.2")


if __name__ == "__main__":
    unittest.main()
