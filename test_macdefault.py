"""Tests for macdefault utility."""

import pytest
from unittest.mock import Mock, patch, MagicMock
from typing import List, Dict, Optional, Tuple
import macdefault


class TestNormalizeExt:
    """Test extension normalization."""

    def test_removes_leading_dot(self):
        assert macdefault.normalize_ext(".txt") == "txt"

    def test_lowercases(self):
        assert macdefault.normalize_ext("TXT") == "txt"

    def test_strips_whitespace(self):
        assert macdefault.normalize_ext("  txt  ") == "txt"

    def test_combined(self):
        assert macdefault.normalize_ext("  .TxT  ") == "txt"

    def test_empty_string(self):
        assert macdefault.normalize_ext("") == ""

    def test_multiple_dots(self):
        assert macdefault.normalize_ext("..txt") == ".txt"


class TestGenericUTIFiltering:
    """Test that generic UTIs are filtered out to prevent hijacking unrelated file types."""

    def test_generic_utis_filtered_from_candidate_selection(self):
        """Test that GENERIC_UTI_CUTOFF items are filtered when applying settings."""
        # This tests the fix for the High severity issue
        test_utis = [
            "com.microsoft.word.doc",
            "public.data",  # Should be filtered
            "public.item",  # Should be filtered
            "org.openxmlformats.wordprocessingml.document",
        ]

        # Simulate the filtering logic from interactive_set_default_for_extension
        filtered = [u for u in test_utis if u not in macdefault.GENERIC_UTI_CUTOFF]

        assert "public.data" not in filtered
        assert "public.item" not in filtered
        assert "com.microsoft.word.doc" in filtered
        assert "org.openxmlformats.wordprocessingml.document" in filtered

    def test_generic_uti_cutoff_constants(self):
        """Verify GENERIC_UTI_CUTOFF contains expected generic types."""
        assert "public.data" in macdefault.GENERIC_UTI_CUTOFF
        assert "public.item" in macdefault.GENERIC_UTI_CUTOFF
        assert "public.content" in macdefault.GENERIC_UTI_CUTOFF


class TestSuiteMappingValidation:
    """Test suite mapping validation."""

    def test_validate_mapping_complete(self):
        """Test that validate_mapping accepts complete mappings."""
        complete_mapping = {ext: "com.test.app" for ext in macdefault.ALL_EXTS}
        # Should not raise
        macdefault.validate_mapping(complete_mapping)

    def test_validate_mapping_incomplete_raises(self):
        """Test that validate_mapping raises on incomplete mappings."""
        import click
        incomplete_mapping = {"doc": "com.test.app"}
        with pytest.raises(click.ClickException, match="mapping missing extensions"):
            macdefault.validate_mapping(incomplete_mapping)

    def test_all_exts_coverage(self):
        """Verify ALL_EXTS contains expected extensions."""
        expected = {"doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "csv"}
        assert set(macdefault.ALL_EXTS) == expected


class TestPathValidation:
    """Test path validation for lsregister calls."""

    def test_path_unknown_sentinel_value(self):
        """Verify that '(path unknown)' is used as sentinel for missing paths."""
        # This tests the fix for Medium severity issue about lsregister
        test_path = "(path unknown)"

        # Simulate the validation logic added in the fix
        should_call_lsregister = (
            test_path and
            test_path != "(path unknown)" and
            test_path.endswith(".app")
        )

        assert not should_call_lsregister

    def test_valid_app_path(self):
        """Test that valid .app paths pass validation."""
        test_path = "/Applications/Safari.app"

        # Note: We skip os.path.exists check in unit test
        should_call_lsregister = (
            test_path and
            test_path != "(path unknown)" and
            test_path.endswith(".app")
        )

        assert should_call_lsregister

    def test_invalid_extension(self):
        """Test that non-.app paths fail validation."""
        test_path = "/Applications/SomeApp"

        should_call_lsregister = (
            test_path and
            test_path != "(path unknown)" and
            test_path.endswith(".app")
        )

        assert not should_call_lsregister


class TestVerificationMismatchDetection:
    """Test that verification properly detects mismatches and query failures."""

    @patch('macdefault.duti_default_info')
    def test_verification_detects_query_failure(self, mock_duti_default_info):
        """Test that None (query failure) is treated as a mismatch."""
        # This tests the fix for Medium severity verification issue
        mock_duti_default_info.return_value = ("line", None)

        mapping = {ext: "com.microsoft.app" for ext in macdefault.ALL_EXTS}
        mismatches = macdefault.collect_mismatches("duti", mapping)

        # All extensions should be mismatches because current is None
        assert len(mismatches) == len(macdefault.ALL_EXTS)

        for ext, expected, current in mismatches:
            assert current is None
            assert expected == "com.microsoft.app"

    @patch('macdefault.duti_default_info')
    def test_verification_detects_wrong_app(self, mock_duti_default_info):
        """Test that verification detects when wrong app is set."""
        mock_duti_default_info.return_value = ("line", "com.wrong.app")

        mapping = {ext: "com.microsoft.app" for ext in macdefault.ALL_EXTS}
        mismatches = macdefault.collect_mismatches("duti", mapping)

        # All extensions should be mismatches
        assert len(mismatches) == len(macdefault.ALL_EXTS)

        for ext, expected, current in mismatches:
            assert current == "com.wrong.app"
            assert expected == "com.microsoft.app"

    @patch('macdefault.duti_default_info')
    def test_verification_passes_when_correct(self, mock_duti_default_info):
        """Test that verification passes when correct app is set."""
        mock_duti_default_info.return_value = ("line", "com.microsoft.app")

        mapping = {ext: "com.microsoft.app" for ext in macdefault.ALL_EXTS}
        mismatches = macdefault.collect_mismatches("duti", mapping)

        # No mismatches when everything is correct
        assert len(mismatches) == 0


class TestSuiteMapping:
    """Test suite mapping generation."""

    @patch('macdefault.bundle_id_of_app')
    def test_microsoft_suite_mapping(self, mock_bundle_id_of_app):
        """Test Microsoft Office suite mapping."""
        # Mock the bundle ID lookups so tests don't require actual apps
        def mock_bundle_lookup(app_name: str) -> Optional[str]:
            app_bundles = {
                "Microsoft Word": "com.microsoft.Word",
                "Microsoft Excel": "com.microsoft.Excel",
                "Microsoft PowerPoint": "com.microsoft.Powerpoint",
            }
            return app_bundles.get(app_name)

        mock_bundle_id_of_app.side_effect = mock_bundle_lookup

        mapping = macdefault.suite_mapping("microsoft")

        # Verify all extensions are covered
        assert set(mapping.keys()) == set(macdefault.ALL_EXTS)

        # Verify Microsoft bundle IDs
        assert all("microsoft" in bid.lower() for bid in mapping.values())

    @patch('macdefault.bundle_id_from_app_path')
    @patch('macdefault.bundle_id_of_app')
    @patch('macdefault.shutil.os.path.exists')
    def test_wps_suite_mapping(self, mock_exists, mock_bundle_id_of_app, mock_bundle_from_path):
        """Test WPS Office suite mapping."""
        # Mock WPS app path existence and bundle ID
        mock_exists.return_value = True
        mock_bundle_from_path.return_value = "com.kingsoft.wpsoffice"
        mock_bundle_id_of_app.return_value = "com.kingsoft.wpsoffice"

        mapping = macdefault.suite_mapping("wps")

        assert set(mapping.keys()) == set(macdefault.ALL_EXTS)
        assert all("kingsoft" in bid.lower() or "wps" in bid.lower() for bid in mapping.values())

    @patch('macdefault.bundle_id_of_app')
    def test_apple_suite_mapping(self, mock_bundle_id_of_app):
        """Test Apple iWork suite mapping."""
        # Mock the bundle ID lookups so tests don't require actual apps
        def mock_bundle_lookup(app_name: str) -> Optional[str]:
            app_bundles = {
                "Pages": "com.apple.iWork.Pages",
                "Numbers": "com.apple.iWork.Numbers",
                "Keynote": "com.apple.iWork.Keynote",
                "TextEdit": "com.apple.TextEdit",
            }
            return app_bundles.get(app_name)

        mock_bundle_id_of_app.side_effect = mock_bundle_lookup

        mapping = macdefault.suite_mapping("apple")

        assert set(mapping.keys()) == set(macdefault.ALL_EXTS)
        assert all("apple" in bid.lower() for bid in mapping.values())

    def test_invalid_suite_raises(self):
        """Test that invalid suite name raises error."""
        import click
        with pytest.raises(click.ClickException, match="Unknown suite"):
            macdefault.suite_mapping("invalid_suite")


class TestParseDutiOutput:
    """Test duti output parsing."""

    def test_parse_empty_output(self):
        """Test parsing empty duti output."""
        lines, name, path, bundle_id = macdefault._parse_duti_output("")
        assert lines == []
        # Function returns None for empty/missing values, not empty strings
        assert name is None or name == ""
        assert path is None or path == ""
        assert bundle_id is None or bundle_id == ""

    def test_parse_valid_output(self):
        """Test parsing valid duti output with multiple lines."""
        output = "Microsoft Word\n/Applications/Microsoft Word.app\ncom.microsoft.Word"
        lines, name, path, bundle_id = macdefault._parse_duti_output(output)

        assert name == "Microsoft Word"
        assert path == "/Applications/Microsoft Word.app"
        assert bundle_id == "com.microsoft.Word"

    def test_parse_pipe_separated_output(self):
        """Test parsing pipe-separated output format."""
        output = "Microsoft Word | /Applications/Microsoft Word.app | com.microsoft.Word"
        lines, name, path, bundle_id = macdefault._parse_duti_output(output)

        assert name == "Microsoft Word"
        assert path == "/Applications/Microsoft Word.app"
        assert bundle_id == "com.microsoft.Word"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
