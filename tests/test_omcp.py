#!/usr/bin/env python3
"""Focused tests for OMCP validators and permission defaults.

Loads bin/omcp as a module without speaking MCP or touching the desktop.
"""

import importlib.machinery
import importlib.util
import contextlib
import io
import json
import os
import shutil
import tempfile
import threading
import unittest
from unittest import mock

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

    def test_operate_profile_is_the_reviewed_default(self):
        self.assertEqual(omcp.profile_permissions("operate"), omcp.default_permissions())
        self.assertEqual(omcp.detect_profile(omcp.default_permissions()), "operate")

    def test_every_current_read_has_an_explicit_profile_classification(self):
        reads = {name for name, spec in omcp.TOOLS.items() if not spec["write"]}
        self.assertEqual(reads, omcp.REVIEWED_READS | omcp.SENSITIVE_READS)
        self.assertFalse(omcp.REVIEWED_READS & omcp.SENSITIVE_READS)

    def test_observe_profile_denies_writes_and_gates_sensitive_reads(self):
        permissions = omcp.profile_permissions("observe")
        self.assertTrue(all(
            permissions[name] == omcp.DENY
            for name, spec in omcp.TOOLS.items() if spec["write"]
        ))
        self.assertEqual(permissions["get_active_window"], omcp.ALLOW)
        self.assertEqual(permissions["screenshot"], omcp.ASK)
        self.assertEqual(permissions["read_clipboard"], omcp.ASK)
        self.assertEqual(omcp.detect_profile(permissions), "observe")

    def test_present_profile_only_allows_reviewed_writes(self):
        permissions = omcp.profile_permissions("present")
        allowed_writes = {
            name for name, spec in omcp.TOOLS.items()
            if spec["write"] and permissions[name] == omcp.ALLOW
        }
        self.assertEqual(allowed_writes, omcp.PRESENT_TOOLS)
        for name in ("launch_app", "open_url", "write_clipboard", "close_window", "lock_screen"):
            self.assertEqual(permissions[name], omcp.DENY)
        self.assertEqual(omcp.detect_profile(permissions), "present")

    def test_one_override_turns_a_named_profile_custom(self):
        permissions = omcp.profile_permissions("observe")
        permissions["get_active_window"] = omcp.ASK
        self.assertEqual(omcp.detect_profile(permissions), "custom")

    def test_unknown_profile_is_rejected(self):
        with self.assertRaises(ValueError):
            omcp.profile_permissions("unlimited")

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

    def test_approved_launch_uses_the_exact_desktop_entry_that_was_shown(self):
        original = "[Desktop Entry]\nType=Application\nName=Approved App\nExec=/usr/bin/true\n"
        replacement = "[Desktop Entry]\nType=Application\nName=Changed App\nExec=/usr/bin/false\n"
        self._write("omcp-race", original)

        summary, approved_run = omcp.prepare_approval(
            "launch_app", {"app": "omcp-race"}, omcp.TOOLS["launch_app"])
        self._write("omcp-race", replacement)

        launched = {}

        def capture(argv, settle=1.5):
            launched["argv"] = argv
            with open(argv[2], "rb") as fh:
                launched["contents"] = fh.read()

        old_state = omcp.STATE_DIR
        omcp.STATE_DIR = self.tmp
        try:
            with mock.patch.object(omcp, "ensure_dirs"), mock.patch.object(omcp, "launch_detached", capture):
                payload, _ = approved_run()
        finally:
            omcp.STATE_DIR = old_state

        self.assertEqual(summary, "launch Approved App")
        self.assertEqual(payload["name"], "Approved App")
        self.assertEqual(launched["argv"][:2], ["gio", "launch"])
        self.assertEqual(launched["contents"], original.encode())
        self.assertFalse(os.path.exists(launched["argv"][2]))


class ApprovalBinding(unittest.TestCase):
    def test_window_address_reuse_is_rejected_after_approval(self):
        address = "0x55c2f0d67580"
        original = {"address": address, "pid": 10, "initialClass": "foot", "class": "foot", "title": "Shell"}
        replacement = {"address": address, "pid": 20, "initialClass": "browser", "class": "browser",
                       "title": "Browser"}
        with mock.patch.object(omcp, "run_json", side_effect=[[original], [replacement]]), \
                mock.patch.object(omcp, "dispatch") as dispatch:
            summary, approved_run = omcp.prepare_approval(
                "close_window", {"address": address}, omcp.TOOLS["close_window"])
            with self.assertRaisesRegex(omcp.ToolError, "changed while approval was pending"):
                approved_run()
        self.assertEqual(summary, "close foot — Shell")
        dispatch.assert_not_called()

    def test_fuzzy_theme_resolution_is_bound_before_approval(self):
        with mock.patch.object(omcp, "theme_names", return_value=["Catppuccin Latte"]), \
                mock.patch.object(omcp, "run") as run:
            summary, approved_run = omcp.prepare_approval(
                "set_theme", {"name": "latte"}, omcp.TOOLS["set_theme"])
            payload, _ = approved_run()
        self.assertEqual(summary, "set the theme to Catppuccin Latte")
        self.assertEqual(payload["theme"], "Catppuccin Latte")
        run.assert_called_once_with(["omarchy", "theme", "set", "Catppuccin Latte"], timeout=30)

    def test_focused_window_screenshot_rejects_a_replacement_window(self):
        address = "0x55c2f0d67580"
        original = {"address": address, "pid": 10, "initialClass": "foot", "initialTitle": "Shell",
                    "class": "foot", "title": "Shell", "at": [10, 20], "size": [800, 600]}
        replacement = {"address": address, "pid": 20, "initialClass": "browser", "initialTitle": "Browser",
                       "class": "browser", "title": "Browser", "at": [10, 20], "size": [800, 600]}
        with mock.patch.object(omcp, "run_json", side_effect=[original, [replacement]]), \
                mock.patch.object(omcp, "capture_screenshot") as capture:
            summary, approved_run = omcp.prepare_approval(
                "screenshot", {"target": "window"}, omcp.TOOLS["screenshot"])
            with self.assertRaisesRegex(omcp.ToolError, "changed while approval was pending"):
                approved_run()
        self.assertEqual(summary, "take a screenshot of foot — Shell")
        capture.assert_not_called()

    def test_screen_screenshot_stays_bound_to_the_approved_monitor(self):
        monitors = [{"name": "DP-1", "focused": True}, {"name": "HDMI-A-1", "focused": False}]
        with mock.patch.object(omcp, "run_json", return_value=monitors), \
                mock.patch.object(omcp, "capture_screenshot", return_value=({}, "captured")) as capture:
            summary, approved_run = omcp.prepare_approval(
                "screenshot", {"target": "screen", "format": "png"}, omcp.TOOLS["screenshot"])
            approved_run()
        self.assertEqual(summary, "take a screenshot of monitor DP-1")
        capture.assert_called_once_with(["grim", "-t", "png", "-o", "DP-1"], "png", "DP-1")


class ConfigProfiles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="omcp-config-test-")
        self.old_paths = {
            name: getattr(omcp, name) for name in (
                "CONFIG_DIR", "STATE_DIR", "CONFIG_PATH", "ACTIVITY_PATH",
                "AGENTS_PATH", "PENDING_PATH", "DECISION_DIR",
            )
        }
        omcp.CONFIG_DIR = os.path.join(self.tmp, "config")
        omcp.STATE_DIR = os.path.join(self.tmp, "state")
        omcp.CONFIG_PATH = os.path.join(omcp.CONFIG_DIR, "config.json")
        omcp.ACTIVITY_PATH = os.path.join(omcp.STATE_DIR, "activity.jsonl")
        omcp.AGENTS_PATH = os.path.join(omcp.STATE_DIR, "agents.json")
        omcp.PENDING_PATH = os.path.join(omcp.STATE_DIR, "pending.json")
        omcp.DECISION_DIR = os.path.join(omcp.STATE_DIR, "decisions")

    def tearDown(self):
        for name, value in self.old_paths.items():
            setattr(omcp, name, value)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_profile_round_trip_and_manual_override(self):
        config = {
            "paused": False,
            "notifyOnConnect": True,
            "tools": omcp.profile_permissions("present"),
        }
        omcp.save_config(config)
        self.assertEqual(omcp.load_config()["profile"], "present")

        config["tools"]["set_theme"] = omcp.ASK
        omcp.save_config(config)
        loaded = omcp.load_config()
        self.assertEqual(loaded["profile"], "custom")
        self.assertEqual(loaded["tools"]["set_theme"], omcp.ASK)

    def test_fresh_install_uses_operate_defaults(self):
        loaded = omcp.load_config()
        self.assertEqual(loaded["profile"], "operate")
        self.assertEqual(loaded["tools"], omcp.default_permissions())

    def test_malformed_existing_config_gates_every_tool(self):
        os.makedirs(omcp.CONFIG_DIR, exist_ok=True)
        with open(omcp.CONFIG_PATH, "w", encoding="utf-8") as fh:
            fh.write("not json")
        loaded = omcp.load_config()
        self.assertEqual(loaded["profile"], "custom")
        self.assertTrue(all(value == omcp.ASK for value in loaded["tools"].values()))

    def test_declared_profile_cannot_mask_different_permissions(self):
        omcp.write_atomic(omcp.CONFIG_PATH, json.dumps({
            "version": 1,
            "profile": "observe",
            "tools": omcp.profile_permissions("operate"),
        }))
        self.assertEqual(omcp.load_config()["profile"], "operate")

    def test_profile_fails_closed_for_tools_added_after_it_was_saved(self):
        omcp.save_config({
            "paused": False,
            "notifyOnConnect": True,
            "tools": omcp.profile_permissions("observe"),
        })
        omcp.TOOLS["future_read"] = {"default": omcp.ALLOW, "write": False}
        omcp.TOOLS["future_write"] = {"default": omcp.ALLOW, "write": True}
        try:
            loaded = omcp.load_config()
            self.assertEqual(loaded["profile"], "observe")
            self.assertEqual(loaded["tools"]["future_read"], omcp.ASK)
            self.assertEqual(loaded["tools"]["future_write"], omcp.DENY)
        finally:
            del omcp.TOOLS["future_read"]
            del omcp.TOOLS["future_write"]

    def test_custom_config_gates_tools_added_after_it_was_saved(self):
        custom = omcp.profile_permissions("operate")
        custom["get_active_window"] = omcp.ASK
        omcp.save_config({"tools": custom})
        omcp.TOOLS["future_tool"] = {"default": omcp.ALLOW, "write": False}
        try:
            loaded = omcp.load_config()
            self.assertEqual(loaded["profile"], "custom")
            self.assertEqual(loaded["tools"]["future_tool"], omcp.ASK)
        finally:
            del omcp.TOOLS["future_tool"]

    def test_tools_json_exposes_authoritative_profile_templates(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(omcp.cmd_tools(["--json"]), 0)
        payload = json.loads(output.getvalue())
        self.assertEqual(payload["profile"], "operate")
        self.assertEqual(set(payload["profiles"]), set(omcp.PROFILE_NAMES))
        self.assertEqual(payload["profiles"]["observe"], omcp.profile_permissions("observe"))

    def test_observe_profile_hides_every_write_from_mcp_discovery(self):
        omcp.save_config({"tools": omcp.profile_permissions("observe")})
        replies = []
        server = omcp.Server()
        server.reply = lambda request_id, result: replies.append((request_id, result))
        server.handle_tools_list(7)
        self.assertEqual(replies[0][0], 7)
        visible = {tool["name"] for tool in replies[0][1]["tools"]}
        writes = {name for name, spec in omcp.TOOLS.items() if spec["write"]}
        self.assertFalse(visible & writes)
        self.assertIn("screenshot", visible)
        self.assertIn("read_clipboard", visible)

    def test_concurrent_mutations_preserve_both_changes(self):
        omcp.save_config({"tools": omcp.profile_permissions("operate")})
        barrier = threading.Barrier(3)

        def change(name, value):
            barrier.wait()
            omcp.mutate_config(lambda config: config["tools"].__setitem__(name, value))

        first = threading.Thread(target=change, args=("screenshot", omcp.DENY))
        second = threading.Thread(target=change, args=("read_clipboard", omcp.ALLOW))
        first.start()
        second.start()
        barrier.wait()
        first.join(timeout=2)
        second.join(timeout=2)
        self.assertFalse(first.is_alive())
        self.assertFalse(second.is_alive())
        loaded = omcp.load_config()
        self.assertEqual(loaded["tools"]["screenshot"], omcp.DENY)
        self.assertEqual(loaded["tools"]["read_clipboard"], omcp.ALLOW)

    def test_config_and_state_permissions_are_private(self):
        omcp.save_config({"tools": omcp.profile_permissions("operate")})
        self.assertEqual(os.stat(omcp.CONFIG_DIR).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(omcp.STATE_DIR).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(omcp.CONFIG_PATH).st_mode & 0o777, 0o600)


class ProtocolState(unittest.TestCase):
    def test_registered_server_announces_changed_tool_catalogue_once(self):
        server = omcp.Server()
        messages = []
        server.registered = True
        server.config_stamp = 10
        server._config_stamp = lambda: 11
        server.send = messages.append
        server.announce_tool_changes()
        server.announce_tool_changes()
        self.assertEqual(messages, [{
            "jsonrpc": "2.0",
            "method": "notifications/tools/list_changed",
        }])

    def test_unregistered_server_does_not_announce_changed_catalogue(self):
        server = omcp.Server()
        messages = []
        server.config_stamp = 10
        server._config_stamp = lambda: 11
        server.send = messages.append
        server.announce_tool_changes()
        self.assertEqual(messages, [])


if __name__ == "__main__":
    unittest.main()
