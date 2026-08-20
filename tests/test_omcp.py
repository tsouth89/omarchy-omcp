#!/usr/bin/env python3
"""Focused tests for OMCP validators and permission defaults.

Loads bin/omcp as a module without speaking MCP or touching the desktop.
"""

import importlib.machinery
import importlib.util
import os
import shutil
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_PATH = os.path.join(ROOT, "bin", "omcp")
_LOADER = importlib.machinery.SourceFileLoader("omcp", _PATH)
omcp = importlib.util.module_from_spec(importlib.util.spec_from_loader("omcp", _LOADER))
_LOADER.exec_module(omcp)


class Validators(unittest.TestCase):
    def test_want_url_accepts_https(self):
        self.assertEqual(omcp.want_url({"url": "https://example.com/x"}), "https://example.com/x")

    def test_want_url_rejects_file_and_javascript(self):
        with self.assertRaises(omcp.ToolError):
            omcp.want_url({"url": "file:///etc/passwd"})
        with self.assertRaises(omcp.ToolError):
            omcp.want_url({"url": "javascript:alert(1)"})
        with self.assertRaises(omcp.ToolError):
            omcp.want_url({"url": "https://example.com/a b"})

    def test_want_bool_rejects_string_false(self):
        with self.assertRaises(omcp.ToolError):
            omcp.want_bool({"enabled": "false"}, "enabled")
        self.assertFalse(omcp.want_bool({"enabled": False}, "enabled"))
        self.assertTrue(omcp.want_bool({"enabled": True}, "enabled"))

    def test_request_id_shape(self):
        self.assertTrue(omcp.REQUEST_ID_RE.fullmatch("abcdefghijkl"))
        self.assertFalse(omcp.REQUEST_ID_RE.fullmatch("../passwd"))
        self.assertFalse(omcp.REQUEST_ID_RE.fullmatch("1-2/../x"))
        self.assertFalse(omcp.REQUEST_ID_RE.fullmatch("abc\n"))

    def test_resolve_bin_ignores_relative_and_path_sep(self):
        self.assertIsNone(omcp.resolve_bin("../usr/bin/hyprctl"))
        self.assertIsNone(omcp.resolve_bin("/usr/bin/hyprctl"))
        self.assertIsNone(omcp.resolve_bin(""))
        found = omcp.resolve_bin("hyprctl")
        self.assertEqual(found, "/usr/bin/hyprctl")

    def test_clean_label_strips_controls(self):
        self.assertEqual(omcp.clean_label("x\n\ty", "agent"), "x y")


class Catalogue(unittest.TestCase):
    def test_tool_count_and_ask_defaults(self):
        self.assertEqual(len(omcp.TOOLS), 32)
        asks = {name for name, spec in omcp.TOOLS.items() if spec["default"] == omcp.ASK}
        self.assertEqual(asks, {
            "read_clipboard", "write_clipboard", "launch_app", "close_window", "lock_screen",
        })
        self.assertTrue(omcp.TOOLS["close_window"].get("destructive"))
        self.assertTrue(omcp.TOOLS["open_url"].get("openWorld"))

    def test_passwd_home_not_tmp(self):
        self.assertNotEqual(omcp.HOME, "/tmp")
        self.assertTrue(omcp.CONFIG_DIR.endswith("/.config/omcp"))
        self.assertTrue(omcp.STATE_DIR.endswith("/.local/state/omcp"))


class DesktopEntries(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="omcp-test-")
        self.old_home = omcp.HOME
        omcp.HOME = self.tmp
        self.apps = os.path.join(self.tmp, ".local", "share", "applications")
        os.makedirs(self.apps)

    def tearDown(self):
        omcp.HOME = self.old_home
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _write(self, app_id, body):
        with open(os.path.join(self.apps, app_id + ".desktop"), "w", encoding="utf-8") as fh:
            fh.write(body)

    def test_hidden_id_is_not_launchable(self):
        self._write("omcp-hidden", "[Desktop Entry]\nType=Application\nName=Not Firefox\nNoDisplay=true\n")
        self._write("omcp-visible", "[Desktop Entry]\nType=Application\nName=Visible App\n")
        self.assertIsNone(omcp.resolve_app("omcp-hidden"))
        visible = omcp.resolve_app("omcp-visible")
        self.assertIsNotNone(visible)
        self.assertEqual(visible["name"], "Visible App")
        listed = {e["id"] for e in omcp.desktop_entries().values() if not e.get("hidden")}
        self.assertIn("omcp-visible", listed)
        self.assertNotIn("omcp-hidden", listed)
        with self.assertRaises(omcp.ToolError):
            omcp.describe_intent("launch_app", {"app": "omcp-hidden"})
        self.assertEqual(omcp.describe_intent("launch_app", {"app": "omcp-visible"}), "launch Visible App")


if __name__ == "__main__":
    unittest.main()
