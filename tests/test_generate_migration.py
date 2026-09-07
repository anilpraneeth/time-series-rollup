"""Offline regression coverage for manifest-driven maintenance migrations.

Run with: python3 -m unittest discover -s tests -p 'test_generate_migration.py' -v
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "src/main/pgdb/migrations/postgres/generate_migration.py"
)
SPEC = importlib.util.spec_from_file_location("generate_migration", SCRIPT)
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


class GenerateMigrationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.manifests = self.root / "manifests"
        self.manifests.mkdir()
        self.output = self.root / "V6__project_maintenance.sql"

    def manifest(self, names, filename="tables.json"):
        path = self.manifests / filename
        path.write_text(json.dumps([{"ProtoDefName": name} for name in names]), encoding="utf-8")
        return path

    def cli(self, *arguments, cwd=None):
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), *map(str, arguments)],
            cwd=cwd or self.root, text=True, capture_output=True, check=False,
        )

    def test_import_does_not_generate_files_or_parse_cli(self):
        code = (
            "import runpy, sys; "
            "sys.argv = ['unrelated-application', '--unrecognized-argument']; "
            "runpy.run_path(" + repr(str(SCRIPT)) + ", run_name='generator_import')"
        )
        before = sorted(self.root.rglob("*"))
        result = subprocess.run(
            [sys.executable, "-B", "-c", code], cwd=self.root,
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")
        self.assertEqual(sorted(self.root.rglob("*")), before)

    def test_only_direct_json_files_are_loaded_in_stable_order(self):
        self.manifest(["zebra.Sensor", "Beta.Sensor"], "z.json")
        self.manifest(["Alpha.Sensor"], "a.JSON")
        (self.manifests / "notes.txt").write_text("not JSON", encoding="utf-8")
        nested = self.manifests / "nested.json"
        nested.mkdir()
        (nested / "ignored.json").write_text("not JSON", encoding="utf-8")
        self.assertEqual(generator.load_table_names(self.manifests), ["alpha_sensor", "beta_sensor", "zebra_sensor"])

    def test_empty_missing_and_file_manifest_directories_are_rejected(self):
        plain_file = self.root / "file"
        plain_file.write_text("[]", encoding="utf-8")
        for directory in [self.manifests, self.root / "missing", plain_file]:
            with self.subTest(directory=directory):
                with self.assertRaises(generator.MigrationError):
                    generator.load_table_names(directory)

    def test_empty_manifest_arrays_are_rejected(self):
        self.manifest([])
        with self.assertRaisesRegex(generator.MigrationError, "no table definitions"):
            generator.load_table_names(self.manifests)

    def test_invalid_json_and_manifest_shapes_report_source(self):
        path = self.manifests / "broken.json"
        for content in ["{", "{}", "null", "[3]", "[{}]", '[{"ProtoDefName": null}]']:
            with self.subTest(content=content):
                path.write_text(content, encoding="utf-8")
                with self.assertRaisesRegex(generator.MigrationError, "broken.json"):
                    generator.load_table_names(self.manifests)

    def test_invalid_utf8_is_reported_as_manifest_error(self):
        (self.manifests / "broken.json").write_bytes(b"\xff")
        with self.assertRaisesRegex(generator.MigrationError, "cannot read JSON manifest"):
            generator.load_table_names(self.manifests)

    def test_protobuf_identifiers_are_validated_before_normalization(self):
        self.assertEqual(generator.normalize_table_name("_Package.Sensor_2"), "_package_sensor_2")
        for name in ["", "a..b", ".a", "a.", "1abc", "a.1abc", "a-b", "a b", "a'b", "a\x00b", "a\nb", "é.Sensor", 3, None]:
            with self.subTest(name=name):
                with self.assertRaises(generator.MigrationError):
                    generator.normalize_table_name(name)

    def test_duplicates_and_normalization_collisions_are_rejected(self):
        for names in [["pkg.Sensor", "pkg.Sensor"], ["pkg.Sensor", "PKG.sensor"], ["pkg.Sensor", "pkg_sensor"]]:
            with self.subTest(names=names):
                self.manifest(names)
                with self.assertRaisesRegex(generator.MigrationError, "duplicate or colliding table name"):
                    generator.load_table_names(self.manifests)

    def test_collisions_across_manifests_report_both_files(self):
        self.manifest(["pkg.Sensor"], "first.json")
        self.manifest(["pkg_sensor"], "second.json")
        with self.assertRaises(generator.MigrationError) as error:
            generator.load_table_names(self.manifests)
        self.assertIn("first.json[0]", str(error.exception))
        self.assertIn("second.json[0]", str(error.exception))

    def test_default_jobs_route_each_exact_table_to_target_database(self):
        sql = generator.render_migration(["telemetry_sensor"])
        self.assertEqual(sql.count("SELECT cron.schedule_in_database("), 2)
        self.assertEqual(sql.count("E'iotmetrics'"), 2)
        self.assertEqual(sql.count("E'0 0 * * *'"), 2)
        for suffix in ["1m", "5m"]:
            self.assertIn(f"E'maintain_telemetry_sensor_{suffix}'", sql)
            self.assertIn(
                f"E'SELECT silver.maintain_timeseries_tables(E''silver.telemetry_sensor_{suffix}'');'", sql,
            )
        self.assertNotIn("UPDATE cron.job", sql)
        self.assertNotIn("_1s", sql)

    def test_custom_intervals_schedule_and_database_are_used(self):
        sql = generator.render_migration(
            ["sensor"], database="analytics", schedule="*/15   * * * *", intervals=" 1H, 30s ",
        )
        self.assertEqual(sql.count("SELECT cron.schedule_in_database("), 2)
        self.assertEqual(sql.count("E'*/15 * * * *'"), 2)
        self.assertEqual(sql.count("E'analytics'"), 2)
        self.assertIn("maintain_sensor_1h", sql)
        self.assertIn("maintain_sensor_30s", sql)
        self.assertNotIn("maintain_sensor_5m", sql)

    def test_sql_literals_escape_quotes_and_backslashes(self):
        self.assertEqual(generator.sql_literal("O'Reilly\\metrics"), "E'O''Reilly\\\\metrics'")
        sql = generator.render_migration(["sensor"], database="O'Reilly\\metrics", intervals="1m")
        self.assertIn("    E'O''Reilly\\\\metrics'\n", sql)
        with self.assertRaises(generator.MigrationError):
            generator.sql_literal("bad\x00name")

    def test_database_names_use_byte_limit_and_control_character_checks(self):
        for database in ["", " ", "a" * 64, "é" * 32, "a\nb", "a\x00b"]:
            with self.subTest(database=database):
                with self.assertRaises(generator.MigrationError):
                    generator.render_migration(["sensor"], database=database)
        generator.render_migration(["sensor"], database="é" * 31)

    def test_empty_or_multiline_schedules_are_rejected(self):
        for schedule in ["", " ", "* * * * *\nSELECT 1", "bad\x00schedule"]:
            with self.subTest(schedule=schedule):
                with self.assertRaises(generator.MigrationError):
                    generator.render_migration(["sensor"], schedule=schedule)

    def test_invalid_and_duplicate_interval_suffixes_are_rejected(self):
        for intervals in ["", ",", "0m", "01m", "-1m", "1 month", "1m,", "1m,1M", "1m;DROP", []]:
            with self.subTest(intervals=intervals):
                with self.assertRaises(generator.MigrationError):
                    generator.render_migration(["sensor"], intervals=intervals)

    def test_table_and_cron_job_name_limits_prevent_truncation(self):
        with self.assertRaisesRegex(generator.MigrationError, "table name.*63-byte"):
            generator.normalize_table_name("a" * 64)
        with self.assertRaisesRegex(generator.MigrationError, "rollup table name.*63-byte"):
            generator.render_migration(["a" * 61])
        with self.assertRaisesRegex(generator.MigrationError, "cron job name.*63-byte"):
            generator.render_migration(["a" * 52])
        # 9 bytes for maintain_, 51 for the table, and 3 for _1m.
        generator.render_migration(["a" * 51])

    def test_render_rejects_raw_or_duplicate_table_names(self):
        for names in [[], ["Package.Name"], ["Uppercase"], ["sensor", "sensor"], ["sensor;DROP TABLE x"]]:
            with self.subTest(names=names):
                with self.assertRaises(generator.MigrationError):
                    generator.render_migration(names)

    def test_output_is_deterministic_across_file_entry_and_interval_order(self):
        self.manifest(["Z.Sensor", "A.Sensor"], "z.json")
        generator.generate_migration(self.manifests, self.output, intervals="5m,1m")
        expected = self.output.read_bytes()
        (self.manifests / "z.json").unlink()
        self.manifest(["A.Sensor"], "a.json")
        self.manifest(["Z.Sensor"], "b.json")
        generator.generate_migration(self.manifests, self.output, force=True, intervals="1m,5m")
        self.assertEqual(self.output.read_bytes(), expected)
        self.assertEqual(list(self.root.glob("*.tmp")), [])

    def test_cli_works_from_arbitrary_cwd_with_relative_paths(self):
        self.manifest(["telemetry.Sensor"])
        result = self.cli("--manifests", "manifests", "--output", self.output.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Wrote", result.stdout)
        self.assertIn("maintain_telemetry_sensor_1m", self.output.read_text(encoding="utf-8"))

    def test_cli_requires_explicit_paths_and_reports_validation_errors(self):
        result = self.cli()
        self.assertEqual(result.returncode, 2)
        self.assertIn("--manifests", result.stderr)
        self.assertIn("--output", result.stderr)
        result = self.cli("--manifests", "missing", "--output", self.output)
        self.assertEqual(result.returncode, 1)
        self.assertIn("error:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.output.exists())

    def test_output_is_not_overwritten_without_force(self):
        self.manifest(["telemetry.Sensor"])
        self.output.write_text("existing migration\n", encoding="utf-8")
        result = self.cli("--manifests", self.manifests, "--output", self.output)
        self.assertEqual(result.returncode, 1)
        self.assertIn("--force", result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "existing migration\n")
        result = self.cli("--manifests", self.manifests, "--output", self.output, "--force")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cron.schedule_in_database", self.output.read_text(encoding="utf-8"))

    def test_invalid_inputs_never_truncate_even_with_force(self):
        self.manifest(["bad-table-name"])
        self.output.write_text("keep me", encoding="utf-8")
        with self.assertRaises(generator.MigrationError):
            generator.generate_migration(self.manifests, self.output, force=True)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "keep me")

    def test_invalid_output_paths_are_rejected_without_creating_directories(self):
        self.manifest(["Sensor"])
        directory = self.root / "directory.sql"
        directory.mkdir()
        for output in [self.root / "wrong.txt", self.root / "missing" / "new.sql", directory]:
            with self.subTest(output=output):
                with self.assertRaises(generator.MigrationError):
                    generator.generate_migration(self.manifests, output)
        self.assertFalse((self.root / "missing").exists())

    def test_dangling_symlink_is_preserved_without_force(self):
        self.manifest(["Sensor"])
        self.output.symlink_to(self.root / "missing.sql")
        with self.assertRaisesRegex(generator.MigrationError, "already exists"):
            generator.generate_migration(self.manifests, self.output)
        self.assertTrue(self.output.is_symlink())

    def test_competing_writer_cannot_be_overwritten(self):
        self.manifest(["Sensor"])
        real_link = os.link

        def competing_link(source, destination):
            Path(destination).write_text("another writer", encoding="utf-8")
            real_link(source, destination)

        with mock.patch.object(generator.os, "link", side_effect=competing_link):
            with self.assertRaisesRegex(generator.MigrationError, "already exists"):
                generator.generate_migration(self.manifests, self.output)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "another writer")
        self.assertEqual(list(self.root.glob("*.tmp")), [])

    def test_failed_atomic_replace_preserves_existing_output(self):
        self.manifest(["Sensor"])
        self.output.write_text("keep me", encoding="utf-8")
        with mock.patch.object(generator.os, "replace", side_effect=OSError("simulated failure")):
            with self.assertRaises(OSError):
                generator.generate_migration(self.manifests, self.output, force=True)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "keep me")
        self.assertEqual(list(self.root.glob("*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
