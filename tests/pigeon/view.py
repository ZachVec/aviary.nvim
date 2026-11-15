"""Exercise receivers and floating attach views on one isolated test server."""
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import termios
import time
import tty

if sys.argv[1:] == ["--keys-receiver"]:
    tty.setraw(sys.stdin.fileno())
    print("AVIARY_KEYS_READY", flush=True)
    while True:
        print(os.read(sys.stdin.fileno(), 1).hex(), end="", flush=True)

if sys.argv[1:] == ["--receiver"]:
    print("AVIARY_RECEIVER_READY", flush=True)
    for line in sys.stdin:
        print(line, end="", flush=True)
    sys.exit(0)

ROOT = Path(__file__).resolve().parents[2]
BASE = ["tmux", "-L", f"aviary-view-spec-{os.getpid()}"]
ENV = dict(os.environ, TERM="xterm-256color")
ENV.pop("TMUX", None)
ENV.pop("TMUX_PANE", None)
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
editors = []
outer = None


def tmux(*args, check=True):
    result = subprocess.run([*BASE, *args], env=ENV, text=True, capture_output=True)
    if check and result.returncode:
        raise AssertionError(f"tmux {args}: {result.stderr}")
    return result.stdout.strip()


def receiver_info(pane, fmt):
    return tmux("display-message", "-p", "-t", pane, fmt)


def drain(timeout=0):
    output = bytearray()
    while select.select([master], [], [], timeout)[0]:
        try:
            data = os.read(master, 65536)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not data:
            break
        output.extend(data)
        for query, response in ((b"\x1b[c", b"\x1b[?1;2c"), (b"\x1b[>c", b"\x1b[>0;4000;0c"), (b"\x1b[6n", b"\x1b[1;1R")):
            if query in data:
                os.write(master, response)
        timeout = 0
    return output


def wait_for(predicate, description):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        drain()
        value = predicate()
        if value:
            return value
        time.sleep(0.005)
    raise AssertionError(f"timed out: {description}")


def info(pane, fmt):
    return tmux("display-message", "-p", "-t", pane, fmt)


def views(window):
    lines = tmux("list-panes", "-t", window, "-F", "#{pane_id} #{pane_floating_flag}").splitlines()
    return [line.split()[0] for line in lines if line.split()[1] == "1"]


def clients(session):
    return tmux("list-clients", "-t", session, "-F", "#{client_pid}", check=False).splitlines()


def response(editor):
    wait_for(lambda: select.select([editor.stdout], [], [], 0)[0], "Neovim response")
    line = editor.stdout.readline().strip()
    if not line:
        raise AssertionError(editor.stderr.read())
    return line


def command(editor, text):
    editor.stdin.write(text + "\n")
    editor.stdin.flush()
    assert response(editor) == "ok"


def start_editor(origin, receiver="--receiver"):
    env = dict(ENV, TMUX=f"{socket},0,0", TMUX_PANE=origin, AVIARY_TEST_ROOT=str(ROOT), AVIARY_TEST_PYTHON=sys.executable, AVIARY_TEST_RECEIVER=str(Path(__file__).resolve()), AVIARY_TEST_RECEIVER_MODE=receiver)
    editor = subprocess.Popen([sys.argv[1], "--headless", "-u", "NONE", "-i", "NONE", "-l", str(Path(__file__).with_name("view_driver.lua"))], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    editors.append(editor)
    target = json.loads(response(editor))
    receiver = "=" + target["instance"] + ":"
    target["session"] = receiver_info(receiver, "#{session_id}")
    target["pane"] = receiver_info(receiver, "#{pane_id}")
    return editor, target


def quit_editor(editor):
    editor.stdin.write("quit\n")
    editor.stdin.flush()
    wait_for(lambda: editor.poll() is not None, "Neovim exit")
    assert editor.returncode == 0, editor.stderr.read()


def detach(session, window, origin, remaining=0):
    os.write(master, b"\x1b[46;5u")
    wait_for(lambda: len(clients(session)) == remaining and not views(window), "C-. closes only its attach view")
    assert info(origin, "#{pane_active}") == "1"


try:
    origin = tmux("-f", "/dev/null", "new-session", "-d", "-s", "editor", "-x", "120", "-y", "40", "-P", "-F", "#{pane_id}", "sleep", "300")
    socket = info(origin, "#{socket_path}")
    window = info(origin, "#{window_id}")
    tmux("split-window", "-h", "-d", "-t", origin, "sleep", "300")
    tmux("resize-pane", "-Z", "-t", origin)
    tmux("set-option", "-s", "extended-keys", "always")
    tmux("set-option", "-s", "extended-keys-format", "csi-u")
    tmux("set-option", "-as", "terminal-features", ",xterm*:extkeys")
    tmux("set-option", "-g", "assume-paste-time", "0")
    outer = subprocess.Popen([*BASE, "attach-session", "-t", "editor"], env=ENV, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    wait_for(lambda: clients("editor"), "outer attach")
    drain(0.05)
    geometry = "#{window_layout}|#{window_zoomed_flag}|#{pane_width}x#{pane_height}"
    before = info(origin, geometry)
    dimensions = info(origin, "#{window_zoomed_flag}|#{pane_width}x#{pane_height}")
    bindings = tmux("list-keys", "-T", "root")
    keys_editor, keys_target = start_editor(origin, "--keys-receiver")
    keys_pane = keys_target["pane"]
    wait_for(lambda: clients(keys_target["session"]), "key probe view attaches")
    wait_for(lambda: "AVIARY_KEYS_READY" in tmux("capture-pane", "-p", "-t", keys_pane), "raw key receiver ready")
    wait_for(lambda: info(views(window)[0], "#{pane_key_mode}") == "Ext 2", "nested client requests extended keys")
    os.write(master, b"\x1b[13;2u")
    wait_for(lambda: "1b5b31333b3275" in tmux("capture-pane", "-p", "-t", keys_pane), "Shift+Enter reaches the receiver as CSI u")
    os.write(master, b"\r")
    wait_for(lambda: "1b5b31333b32750d" in tmux("capture-pane", "-p", "-t", keys_pane), "Enter remains distinct from Shift+Enter")
    command(keys_editor, "show")
    wait_for(lambda: clients(keys_target["session"]), "key probe view reattaches")
    wait_for(lambda: info(views(window)[0], "#{pane_key_mode}") == "Ext 2", "replacement client requests extended keys")
    os.write(master, b"\x1b[13;2u")
    wait_for(lambda: "1b5b31333b32750d1b5b31333b3275" in tmux("capture-pane", "-p", "-t", keys_pane), "modified Enter survives display reuse")
    detach(keys_target["session"], window, origin)
    quit_editor(keys_editor)
    tmux("kill-session", "-t", keys_target["session"])
    editor, first = start_editor(origin)
    session, pane = first["session"], first["pane"]
    pid = receiver_info(pane, "#{pane_pid}")
    window_width = int(info(origin, "#{window_width}"))
    window_height = int(info(origin, "#{window_height}"))
    for cycle in range(5):
        if cycle:
            command(editor, "double-show")
        wait_for(lambda: len(clients(session)) == 1, "view attaches")
        view = views(window)[0]
        assert info(view, "#{pane_floating_flag}") == "1"
        assert info(view, "#{pane_width}x#{pane_height}") == f"{int(window_width * 0.9) - 2}x{int(window_height * 0.9) - 2}"
        assert info(origin, "#{window_zoomed_flag}|#{pane_width}x#{pane_height}") == dimensions
        assert tmux("list-windows", "-t", "editor", "-F", "#{window_id}") == window
        assert receiver_info(pane, "#{pane_pid}") == pid
        wait_for(lambda: "PERSISTENT_DRAFT" in tmux("capture-pane", "-p", "-t", view), "receiver draft rendered in view")
        command(editor, "show")
        replacement_views = views(window)
        assert replacement_views == [view], "show must reuse the marked view"
        view = replacement_views[0]
        wait_for(lambda: len(clients(session)) == 1, "replacement attaches")
        wait_for(lambda: "PERSISTENT_DRAFT" in tmux("capture-pane", "-p", "-t", view), "draft survives view replacement")
        assert info(view, "#{@pigeon_source}") == origin
        if cycle == 0:
            command(editor, "fail-start")
            assert not views(window), "failure must release a reused view"
            assert receiver_info(pane, "#{pane_pid}") == pid
            command(editor, "show")
            replacement_views = views(window)
            assert len(replacement_views) == 1 and replacement_views[0] != view
            view = replacement_views[0]
            wait_for(lambda: len(clients(session)) == 1, "view reattaches after rollback")
            unrelated = tmux("new-pane", "-d", "-E", "-A", "-t", origin, "-P", "-F", "#{pane_id}")
            command(editor, "show")
            assert set(views(window)) == {view, unrelated}, "unmarked floats must be left alone"
            tmux("kill-pane", "-t", unrelated)
        assert tmux("list-keys", "-T", "root") == bindings
        assert tmux("list-keys", "-T", "aviary-pigeon", "-F", "#{key_string}") == "C-."
        detach(session, window, origin)
        assert info(origin, geometry) == before
        assert "PERSISTENT_DRAFT" in tmux("capture-pane", "-p", "-t", pane)
    # Constructor rollback must remove only its newly acquired empty display.
    command(editor, "fail-start")
    assert not views(window) and receiver_info(pane, "#{pane_pid}") == pid
    # Conflicting user bindings are reported and retained, never overwritten.
    tmux("bind-key", "-n", "C-.", "display-message", "user-owned")
    command(editor, "conflict")
    assert not views(window)
    assert "user-owned" in tmux("list-keys", "-T", "root", "C-.")
    tmux("unbind-key", "-n", "C-.")
    tmux("set-option", "-t", "editor", "prefix", "C-.")
    command(editor, "alias-conflict")
    tmux("set-option", "-t", "editor", "prefix", "C-b")
    tmux("bind-key", "-n", "Any", "display-message", "user-catch-all")
    command(editor, "conflict")
    assert "user-catch-all" in tmux("list-keys", "-T", "root", "Any")
    tmux("unbind-key", "-n", "Any")
    command(editor, "show")
    view = views(window)[0]
    # Native configured dimensions include the surrounding one-cell border.
    for action, expected_size in (
        ("resize", "68x18"),
        ("ratio-resize", f"{window_width * 33 // 100 - 2}x{window_height * 62 // 100 - 2}"),
        ("full-size", f"{window_width - 2}x{window_height - 2}"),
    ):
        command(editor, action)
        replacement_views = views(window)
        assert replacement_views == [view], "resizing must reuse the marked view"
        view = replacement_views[0]
        assert info(view, "#{pane_width}x#{pane_height}") == expected_size
    tmux("kill-pane", "-t", view)
    command(editor, "show")
    assert views(window) != [view], "rebuild a destroyed view"
    view = views(window)[0]
    # Editors sharing one host window must keep distinct source-owned displays.
    sources = tmux("list-panes", "-t", window, "-f", "#{==:#{pane_floating_flag},0}", "-F", "#{pane_id}").splitlines()
    sibling = next(source for source in sources if source != origin)
    sibling_editor, sibling_target = start_editor(sibling)
    sibling_view = next(pane for pane in views(window) if pane != view)
    assert info(sibling_view, "#{@pigeon_source}") == sibling
    command(editor, "show")
    command(sibling_editor, "show")
    assert set(views(window)) == {view, sibling_view}, "each source must reuse only its own float"
    tmux("kill-pane", "-t", sibling_view)
    wait_for(lambda: not clients(sibling_target["session"]), "sibling display closes independently")
    quit_editor(sibling_editor)
    tmux("send-keys", "-t", sibling_target["pane"], "C-c")
    # A view belongs to its window and stays attached when that window is hidden.
    other = tmux("new-window", "-t", "editor", "-P", "-F", "#{pane_id}", "sleep", "300")
    other_window = info(other, "#{window_id}")
    assert views(window) == [view] and len(clients(session)) == 1
    second_editor, second = start_editor(other)
    wait_for(lambda: len(clients(second["session"])) == 1, "second independent tool")
    assert views(window) == [view] and len(views(other_window)) == 1
    old_view = views(other_window)[0]
    command(second_editor, "reuse:" + first["instance"])
    wait_for(lambda: len(clients(session)) == 2 and not clients(second["session"]), "two independent views of one receiver")
    assert views(other_window) == [old_view], "switching receivers must reuse the existing float"
    assert receiver_info(second["pane"], "#{pane_dead}") == "0"
    # Detach this window's view without closing the other editor's view.
    os.write(master, b"\x1b[46;5u")
    wait_for(lambda: not views(other_window) and len(clients(session)) == 1, "independent C-.")
    assert views(window) == [view]
    command(second_editor, "show")
    wait_for(lambda: len(clients(session)) == 2, "second view restored")
    quit_editor(editor)
    assert views(window) == [view], "Neovim exit leaves the display available for manual close"
    tmux("select-window", "-t", window)
    detach(session, window, origin, remaining=1)
    tmux("select-window", "-t", other_window)
    assert views(other_window)
    assert receiver_info(pane, "#{pane_pid}") == pid
    tmux("kill-window", "-t", other_window)
    wait_for(lambda: not clients(session), "destroyed source window detaches view")
    assert receiver_info(pane, "#{pane_pid}") == pid
    # A new editor supplies valid source context after the previous window died.
    replacement = tmux("new-window", "-t", "editor", "-P", "-F", "#{pane_id}", "sleep", "300")
    third_editor, third = start_editor(replacement)
    wait_for(lambda: clients(third["session"]), "third view attaches")
    # An exited receiver must remove its view even after the origin pane is gone.
    third_window = info(replacement, "#{window_id}")
    tmux("kill-pane", "-t", replacement)
    tmux("send-keys", "-t", third["pane"], "C-c")
    wait_for(lambda: third_window not in tmux("list-windows", "-t", "editor", "-F", "#{window_id}").splitlines(), "tool exit cleans view with missing source")
    assert not clients(third["session"])
    quit_editor(third_editor)
    replacement = tmux("new-window", "-t", "editor", "-P", "-F", "#{pane_id}", "sleep", "300")
    fourth_editor, fourth = start_editor(replacement)
    wait_for(lambda: clients(fourth["session"]), "view before source session destruction")
    tmux("set-option", "-t", "editor", "detach-on-destroy", "on")
    tmux("kill-session", "-t", "editor")
    wait_for(lambda: outer.poll() is not None, "outer client exits while PTY is drained")
    assert outer.returncode == 0
    assert receiver_info(pane, "#{pane_pid}") == pid
    assert receiver_info(fourth["pane"], "#{pane_dead}") == "0"
    quit_editor(second_editor)
    quit_editor(fourth_editor)
    # Natural tool exit removes receivers without changing user key tables.
    for target in (first, second, fourth):
        tmux("send-keys", "-t", target["pane"], "C-c")
        wait_for(lambda: target["session"] not in tmux("list-sessions", "-F", "#{session_id}", check=False).splitlines(), "receiver cleanup")
        assert not tmux("has-session", "-t", "=" + target["instance"], check=False)
    print(json.dumps({"cycles": 5, "draft_preserved": True, "receiver_pid_preserved": True, "layout_and_zoom_preserved": True, "independent_views": True, "creator_and_origin_exit_preserved": True, "rollback_and_conflicts": True, "extended_keys_preserved": True}))
finally:
    for editor in editors:
        if editor.poll() is None:
            editor.kill()
            editor.wait(timeout=5)
    if outer is not None and outer.poll() is None:
        outer.terminate()
        wait_for(lambda: outer.poll() is not None, "outer client cleanup")
    subprocess.run([*BASE, "kill-server"], env=ENV, capture_output=True)
    os.close(master)
