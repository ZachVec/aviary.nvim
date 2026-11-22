"""Real Neovim Terminal/tmux integration. Owns an isolated server and PTYs."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parents[1]
ENV = dict(os.environ, TERM="xterm-256color", LANG="C.UTF-8")
for variable in ("TMUX", "TMUX_PANE", "NVIM", "NVIM_LISTEN_ADDRESS", "NO_COLOR", "CODEX_CI"):
    ENV.pop(variable, None)


class Experiment:
    def __init__(self, nvim, cycles=3):
        self.nvim = str(Path(nvim).resolve()) if "/" in nvim else shutil.which(nvim)
        self.output = REPOSITORY / ".scratch/pigeon-terminal-display/runs" / f"production-{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
        self.output.mkdir(parents=True)
        self.tmux_tmpdir = tempfile.mkdtemp(prefix=f"pigeon-test-tmux-{os.getpid()}-")
        ENV["TMUX_TMPDIR"] = self.tmux_tmpdir
        self.base = ["tmux"]
        self.editors = []
        self.targets = []
        self.checks = []
        self.cycles = cycles

    def tmux(self, *args, check=True):
        result = subprocess.run([*self.base, *args], env=ENV, text=True, capture_output=True, timeout=5)
        if check and result.returncode:
            raise RuntimeError(f"tmux {args}: {result.stderr}")
        return result.stdout.strip()

    def drain(self):
        for editor in self.editors:
            master = editor["master"]
            while select.select([master], [], [], 0)[0]:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                editor["ansi"].extend(data)
                for query, reply in (
                    (b"\x1b[c", b"\x1b[?1;2c"),
                    (b"\x1b[>c", b"\x1b[>0;4000;0c"),
                    (b"\x1b[6n", b"\x1b[1;1R"),
                    (b"\x1b]10;?", b"\x1b]10;rgb:eeee/eeee/eeee\x1b\\"),
                    (b"\x1b]11;?", b"\x1b]11;rgb:1111/1111/1111\x1b\\"),
                ):
                    if query in data:
                        os.write(master, reply)

    def wait(self, predicate, description, seconds=8):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.drain()
            value = predicate()
            if value:
                return value
            time.sleep(0.01)
        raise AssertionError("timed out: " + description)

    def delay(self, seconds):
        deadline = time.monotonic() + seconds
        self.wait(lambda: time.monotonic() >= deadline, "event-loop delay", seconds + 1)

    def rpc(self, editor, action="snapshot", **payload):
        encoded = json.dumps({"action": action, **payload}, ensure_ascii=False).replace("'", "''")
        expression = "luaeval('vim.json.encode(PigeonTest.request(_A))', '" + encoded + "')"
        result = subprocess.run(
            [self.nvim, "--server", editor["rpc"], "--remote-expr", expression],
            env=ENV, capture_output=True, text=True, timeout=5,
        )
        if result.returncode:
            raise RuntimeError(result.stderr or result.stdout)
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError(result.stderr or result.stdout) from error

    def start(self):
        self.tmux("-f", "/dev/null", "new-session", "-d", "-s", "test-host", "sleep", "300")
        self.tmux("set-option", "-g", "status", "off")
        self.tmux("set-option", "-g", "default-terminal", "tmux-256color")
        self.tmux("set-option", "-g", "-w", "remain-on-exit", "on")
        self.tmux("set-option", "-g", "assume-paste-time", "0")
        self.tmux("set-option", "-s", "extended-keys", "always")
        self.tmux("set-option", "-s", "extended-keys-format", "csi-u")
        self.tmux("set-option", "-as", "terminal-features", ",xterm*:extkeys")

    def editor(self, name, width=120, height=40):
        rpc = f"/tmp/pigeon-test-{os.getpid()}-{name}.nvim"
        code = "dofile(" + json.dumps(str(ROOT / "view_driver.lua")) + ")"
        pane = self.tmux(
            "new-session", "-d", "-s", name, "-x", str(width), "-y", str(height), "-P", "-F", "#{pane_id}",
            "--", "env", "-u", "NVIM", f"TMUX_TMPDIR={self.tmux_tmpdir}",
            f"NVIM_LOG_FILE={self.output / (name + '.log')}", self.nvim,
            "-u", "NONE", "-i", "NONE", "--listen", rpc, "-c", "lua " + code,
        )
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))
        client = subprocess.Popen(
            [*self.base, "attach-session", "-t", "=" + name],
            env=ENV, stdin=slave, stdout=slave, stderr=slave,
        )
        os.close(slave)
        editor = {"name": name, "rpc": rpc, "pane": pane, "master": master, "client": client, "ansi": bytearray()}
        self.editors.append(editor)
        self.wait(lambda: Path(rpc).exists(), name + " RPC socket")
        self.wait(lambda: self.rpc(editor).get("mode") == "n", name + " TUI ready")
        return editor

    def create(self, editor, tool, name, argv=None):
        output = self.output / (name + "-input.json")
        target = self.rpc(
            editor, "create", tool=tool, cwd=str(REPOSITORY),
            argv=argv or [sys.executable, str(ROOT / "agent.py"), name, str(output)],
        )
        target["input"] = str(output)
        self.targets.append(target)
        return target

    def selected(self, editor, target):
        return self.rpc(editor).get("session") == target["session"]

    def connected(self, editor):
        snapshot = self.rpc(editor)
        if not snapshot.get("client"):
            return False
        names = self.tmux("list-clients", "-F", "#{client_name}").splitlines()
        return snapshot["session"] if snapshot["client"] in names else False

    def stopped(self, editor):
        state = self.rpc(editor)
        return state if not state.get("buffer") else False

    def sessions(self):
        return self.tmux("list-sessions", "-F", "#{session_name}").splitlines()

    def capture(self, editor, name):
        self.delay(0.1)
        self.output.joinpath(name + ".txt").write_text(self.tmux("capture-pane", "-p", "-t", editor["pane"]))
        self.output.joinpath(name + ".ansi").write_text(self.tmux("capture-pane", "-e", "-p", "-t", editor["pane"]))

    def received(self, target):
        path = Path(target["input"])
        if not path.exists():
            return b""
        try:
            return bytes.fromhex(json.loads(path.read_text())["hex"])
        except json.JSONDecodeError:
            return b""

    def check(self, name):
        self.checks.append(name)
        print("PASS " + name, flush=True)

    def exercise(self):
        self.start()
        a, b = self.editor("editor-a"), self.editor("editor-b", 100, 34)
        first = self.create(a, "codex", "A")
        second = self.create(a, "claude", "B")
        third = self.create(a, "codex", "C")
        pids = {target["id"]: self.tmux("display", "-p", "-t", target["pane"], "#{pane_pid}") for target in self.targets}
        initial_sessions = len(self.sessions())
        assert not any("aviary-pigeon-view" in name for name in self.sessions())

        for editor, target in ((a, first), (b, second)):
            self.rpc(editor, "select", target=target)
            self.wait(lambda: self.connected(editor), "attach client started")
            self.wait(lambda: "READY" in "\n".join(self.rpc(editor).get("text") or []), "Agent rendered")
            self.wait(lambda: self.rpc(editor)["mode"] == "t", "terminal input mode")
        self.wait(lambda: "中文 / λ" in self.tmux("capture-pane", "-p", "-t", a["pane"]), "Unicode in actual Neovim screen")
        sa, sb = self.rpc(a), self.rpc(b)
        assert sa["client"] != sb["client"] and self.selected(a, first) and self.selected(b, second)
        assert len(sa["buffers"]) == len(sb["buffers"]) == 1
        assert len(self.rpc(a, "list")) == 3
        assert len(self.sessions()) == initial_sessions
        self.capture(a, "01-independent-a")
        self.capture(b, "02-independent-b")
        self.check("two Neovims attach directly to separate Agent sessions with no extra sessions")

        for option, expected in (
            ("destroy-unattached", "off"),
            ("detach-on-destroy", "on"),
            ("status", "off"),
            ("prefix", "None"),
            ("prefix2", "None"),
        ):
            assert self.tmux("show-options", "-v", "-t", "=" + first["session"] + ":", option) == expected
        assert self.tmux("show-options", "-w", "-v", "-t", "=" + first["session"] + ":", "remain-on-exit") == "off"
        assert self.tmux("show-options", "-w", "-v", "-t", "=" + first["session"] + ":", "pane-border-status") == "off"
        self.check("Agent sessions disable status/prefix/pane border and preserve Agent lifetime options")

        self.rpc(a, "select", target=second)
        after = self.rpc(a)
        assert (after["buffer"], after["job"], after["client"]) == (sa["buffer"], sa["job"], sa["client"])
        assert after["session"] == second["session"] and self.selected(b, second)
        assert len(self.sessions()) == initial_sessions
        assert len(self.rpc(a, "list")) == 3
        self.capture(a, "03-switch-client")
        self.check("retarget reuses buffer/job/client and leaves the other Neovim unchanged")

        assert self.rpc(a, "reference", path=str(REPOSITORY / "lua/aviary/init.lua"), first=12, last=15) == second["session"]
        expected = b"@lua/aviary/init.lua#L12-15"
        self.wait(lambda: expected in self.received(second), "current Agent formatter")
        assert not self.received(first)
        self.check("send uses the current Agent's cwd and formatter without focusing")

        os.write(a["master"], b"\x1b[46;5u")
        self.wait(lambda: not self.rpc(a).get("window"), "buffer-local close key hides Terminal")
        hidden = self.rpc(a)
        text = "line one\nline two 中文"
        self.rpc(a, "send", text=text)
        self.wait(lambda: text.encode() in self.received(second), "hidden multi-line send")
        delivered = self.received(second)
        assert b"\x1b[200~" in delivered and b"\x1b[201~" in delivered and b"\r" not in delivered
        after = self.rpc(a)
        assert not after.get("window") and after["current_window"] == hidden["current_window"]
        assert (after["buffer"], after["job"], after["client"]) == (sa["buffer"], sa["job"], sa["client"])
        self.rpc(a, "show")
        self.wait(lambda: self.rpc(a)["mode"] == "t", "show restores terminal mode")
        self.check("hidden send preserves focus, multi-line Unicode, bracketed paste, and no Enter")

        self.tmux("send-keys", "-t", a["pane"], "F5")
        self.wait(lambda: "Pigeon Agent:" in self.tmux("capture-pane", "-p", "-t", a["pane"]), "native picker prompt")
        self.tmux("send-keys", "-t", a["pane"], "2", "Enter")
        self.wait(lambda: self.selected(a, first) and self.rpc(a)["mode"] == "t", "native picker returns to terminal mode")
        self.check("pick key opens the native picker, switches Agent, and returns to terminal input mode")

        self.rpc(a, "floating-picker")
        self.tmux("send-keys", "-t", a["pane"], "F5")
        self.wait(lambda: self.rpc(a)["mode"] == "i", "floating picker input")
        self.tmux("send-keys", "-t", a["pane"], "Enter")
        self.wait(lambda: self.selected(a, second) and self.rpc(a)["mode"] == "t", "floating picker returns to terminal mode")
        self.rpc(a, "select", target=first)
        self.wait(lambda: self.selected(a, first), "restore first Agent for input checks")
        self.check("floating picker confirmation switches Agent and resumes Terminal input")

        before = len(self.received(first))
        os.write(a["master"], b"KEYBOARD")
        self.wait(lambda: b"KEYBOARD" in self.received(first)[before:], "physical key path")
        offset = len(self.received(first))
        os.write(a["master"], b"\x1b[13;2u")
        self.wait(lambda: len(self.received(first)) > offset, "Shift+Enter key path")
        shift_enter = self.received(first)[offset:]
        offset = len(self.received(first))
        os.write(a["master"], b"\x1b[13;3u")
        self.wait(lambda: len(self.received(first)) > offset, "Alt+Enter key path")
        alt_enter = self.received(first)[offset:]
        offset = len(self.received(first))
        os.write(a["master"], b"\r")
        self.wait(lambda: len(self.received(first)) > offset, "Enter key path")
        enter = self.received(first)[offset:]
        self.keyboard = {"shift_enter_hex": shift_enter.hex(), "alt_enter_hex": alt_enter.hex(), "enter_hex": enter.hex()}
        assert enter == b"\r", self.keyboard
        assert not self.rpc(a)["modified_enter_mapped"]
        assert alt_enter in (b"\x1b\r", b"\x1b[13;3u"), self.keyboard
        self.check("physical input traverses Neovim terminal and nested tmux; no built-in modified-Enter fix is installed")

        self.rpc(a, "select", target=third)
        self.wait(lambda: self.connected(a), "third Agent attached")
        before_width = self.tmux("display", "-p", "-t", third["pane"], "#{pane_width}")
        fcntl.ioctl(a["master"], termios.TIOCSWINSZ, struct.pack("HHHH", 44, 140, 0, 0))
        os.kill(a["client"].pid, signal.SIGWINCH)
        self.wait(lambda: self.tmux("display", "-p", "-t", a["pane"], "#{pane_width}") == "140", "outer terminal resize")
        self.delay(0.2)
        assert self.tmux("display", "-p", "-t", third["pane"], "#{pane_width}") == before_width
        self.rpc(a, "show")
        self.wait(lambda: self.rpc(a)["mode"] == "t", "visible show keeps terminal mode")
        self.delay(0.2)
        assert self.tmux("display", "-p", "-t", third["pane"], "#{pane_width}") == before_width
        os.write(a["master"], b"\x1b[46;5u")
        self.wait(lambda: not self.rpc(a).get("window"), "close key hides resized Terminal")
        self.rpc(a, "show")
        self.wait(lambda: self.tmux("display", "-p", "-t", third["pane"], "#{pane_width}") == "126", "PTY follows reopened dimensions")
        self.capture(a, "04-resized")
        self.check("visible Terminals keep their size until hide/show recomputes editor geometry")

        for _ in range(self.cycles):
            old = self.rpc(a)
            self.rpc(a, "exit-client")
            stopped = self.wait(lambda: self.stopped(a), "TermClose cleanup")
            assert stopped["exit_count"] > old["exit_count"]
            assert not stopped["buffers"] and not stopped.get("job") and not stopped.get("window")
            assert not stopped["errors"], stopped["errors"]
            self.rpc(a, "select", target=first)
            self.wait(lambda: self.connected(a), "reopen attachment")
        for target in self.targets:
            assert self.tmux("display", "-p", "-t", target["pane"], "#{pane_pid}") == pids[target["id"]]
        assert len(self.sessions()) == initial_sessions
        self.check(f"attach job exit triggers TermClose cleanup; {self.cycles} reopen cycles preserve all Agent PIDs")

        before = self.rpc(a)
        self.rpc(a, "delete-buffer")
        stopped = self.wait(lambda: self.stopped(a), "external deletion cleanup")
        assert stopped["exit_count"] > before["exit_count"] and not stopped["errors"], stopped
        self.rpc(a, "select", target=first)
        self.wait(lambda: self.connected(a), "reattach after external deletion")
        self.check("external buffer deletion clears Terminal state without errors and allows reattach")

        self.rpc(b, "select", target=third)
        self.rpc(a, "select", target=third)
        self.wait(lambda: self.connected(a) and self.connected(b), "shared Agent attached")
        self.tmux("send-keys", "-t", third["pane"], "C-c")
        stopped_b = self.wait(lambda: self.stopped(b), "natural attach exit B")
        stopped_a = self.wait(lambda: self.stopped(a), "natural attach exit A")
        assert not stopped_a["errors"] and not stopped_b["errors"]
        assert len(self.rpc(a, "list")) == 2
        for target in (first, second):
            assert self.tmux("display", "-p", "-t", target["pane"], "#{pane_pid}") == pids[target["id"]]
        self.rpc(a, "select", target=first)
        self.wait(lambda: self.connected(a), "Agent preserved after shared exit")
        self.check("shared Agent exit closes both Terminals; other Agents remain usable")

        client = self.rpc(a)["client"]
        subprocess.run(
            [self.nvim, "--server", a["rpc"], "--remote-send", "<C-\\><C-n>:qa!<CR>"],
            env=ENV, capture_output=True, check=True, timeout=5,
        )
        self.wait(lambda: client not in self.tmux("list-clients", "-F", "#{client_name}").splitlines(), "editor exit detaches")
        for target in (first, second):
            assert self.tmux("display", "-p", "-t", target["pane"], "#{pane_pid}") == pids[target["id"]]
        assert not any("aviary-pigeon-view" in name for name in self.sessions())
        self.check("Neovim exit detaches only its client and preserves Agent sessions")

    def finish(self, error=None):
        native = {
            "sessions": self.tmux("list-sessions", "-F", "#{session_name}|#{session_attached}", check=False),
            "clients": self.tmux("list-clients", "-F", "#{client_pid}|#{client_tty}|#{client_session}|#{client_flags}", check=False),
        }
        self.output.joinpath("native-state.json").write_text(json.dumps(native, indent=2))
        if error:
            for pane in self.tmux("list-panes", "-a", "-F", "#{pane_id}", check=False).splitlines():
                self.output.joinpath("failure-pane-" + pane[1:] + ".txt").write_text(
                    self.tmux("capture-pane", "-p", "-t", pane, check=False)
                )
        report = {
            "nvim": subprocess.run([self.nvim, "--version"], capture_output=True, text=True).stdout.splitlines()[0],
            "tmux": subprocess.run(["tmux", "-V"], capture_output=True, text=True).stdout.strip(),
            "checks": self.checks,
            "keyboard": getattr(self, "keyboard", None),
            "error": str(error) if error else None,
        }
        for editor in self.editors:
            self.output.joinpath(editor["name"] + "-tui.ansi").write_bytes(editor["ansi"])
        self.output.joinpath("report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
        self.tmux("kill-server", check=False)
        for editor in self.editors:
            try:
                editor["client"].wait(timeout=5)
            except subprocess.TimeoutExpired:
                editor["client"].kill()
            os.close(editor["master"])
        shutil.rmtree(self.tmux_tmpdir, ignore_errors=True)
        print("REPORT " + str(self.output / "report.json"), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--cycles", type=int, default=3, help="client-exit/reopen cycles to check TermClose cleanup")
    args = parser.parse_args()
    experiment = Experiment(args.nvim, args.cycles)
    error = None
    try:
        experiment.exercise()
    except BaseException as caught:
        error = caught
        raise
    finally:
        experiment.finish(error)


if __name__ == "__main__":
    main()
