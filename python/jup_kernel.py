#!/usr/bin/env python3
"""
jup_kernel.py — Neovim ↔ Jupyter kernel bridge.

Communicates with Neovim via newline-delimited JSON on stdin/stdout.
Uses jupyter_client to manage kernel connections over ZeroMQ.

Protocol (Neovim → bridge):
  {"id": N, "method": "start_kernel",  "params": {"kernel_name": "python3"}}
  {"id": N, "method": "connect",       "params": {"connection_file": "/path"}}
  {"id": N, "method": "execute",       "params": {"code": "...", "cell_id": "..."}}
  {"id": N, "method": "complete",      "params": {"code": "...", "cursor_pos": N}}
  {"id": N, "method": "interrupt",     "params": {}}
  {"id": N, "method": "restart",       "params": {}}
  {"id": N, "method": "kernel_info",   "params": {}}
  {"id": N, "method": "list_kernels",  "params": {}}
  {"id": N, "method": "shutdown",      "params": {}}

Protocol (bridge → Neovim):
  {"type": "result",           "id": N,       "data": {...}}
  {"type": "result",           "id": N,       "error": "..."}
  {"type": "output",           "cell_id": "", "output": {...}}
  {"type": "status",           "execution_state": "busy|idle"}
  {"type": "execution_count",  "cell_id": "", "count": N}
  {"type": "done",             "cell_id": "", "status": "ok|error"}
  {"type": "log",              "level": "info|warn|error", "message": "..."}
"""

import sys
import json
import queue
import threading
import time
import traceback as tb_mod

# ── Jupyter imports (deferred to give a clean error if not installed) ─────────
def _import_jupyter():
    try:
        import jupyter_client
        return jupyter_client
    except ImportError:
        send({"type": "log", "level": "error",
              "message": "jupyter_client is not installed. Run: pip install jupyter_client"})
        sys.exit(1)


# ── I/O ───────────────────────────────────────────────────────────────────────

_stdout_lock = threading.Lock()

def send(msg: dict):
    """Send a JSON message to Neovim."""
    line = json.dumps(msg, ensure_ascii=False) + "\n"
    with _stdout_lock:
        sys.stdout.write(line)
        sys.stdout.flush()


def log(level: str, message: str):
    send({"type": "log", "level": level, "message": message})


# ── Bridge state ──────────────────────────────────────────────────────────────

class KernelBridge:
    def __init__(self):
        self.km = None          # KernelManager
        self.kc = None          # KernelClient
        self.msg_to_cell: dict  = {}   # msg_id → cell_id
        self.cmd_queue          = queue.Queue()
        self.running            = True
        self._poll_interval     = 0.02  # seconds between kernel polls

    # ── Stdin reader (runs in its own thread) ─────────────────────────────────

    def _stdin_reader(self):
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            try:
                self.cmd_queue.put(json.loads(raw))
            except json.JSONDecodeError as e:
                log("warn", f"bad JSON from Neovim: {e}")
        self.running = False

    # ── Main loop ─────────────────────────────────────────────────────────────

    def run(self):
        t = threading.Thread(target=self._stdin_reader, daemon=True)
        t.start()

        while self.running:
            # Drain command queue
            try:
                while True:
                    cmd = self.cmd_queue.get_nowait()
                    self._handle_command(cmd)
            except queue.Empty:
                pass

            # Poll kernel channels
            if self.kc is not None:
                self._poll_kernel()

            time.sleep(self._poll_interval)

    # ── Command dispatch ──────────────────────────────────────────────────────

    def _handle_command(self, msg: dict):
        method = msg.get("method", "")
        params = msg.get("params", {})
        req_id = msg.get("id")

        try:
            if   method == "start_kernel":  result = self._start_kernel(params)
            elif method == "connect":        result = self._connect(params)
            elif method == "execute":        result = self._execute(params)
            elif method == "complete":       result = self._complete(params)
            elif method == "interrupt":      result = self._interrupt()
            elif method == "restart":        result = self._restart()
            elif method == "kernel_info":    result = self._kernel_info()
            elif method == "list_kernels":   result = self._list_kernels()
            elif method == "shutdown":       result = self._shutdown()
            else:
                send({"type": "result", "id": req_id, "error": f"Unknown method: {method}"})
                return

            send({"type": "result", "id": req_id, "data": result})

        except Exception as e:
            send({"type": "result", "id": req_id,
                  "error": f"{type(e).__name__}: {e}\n{''.join(tb_mod.format_tb(e.__traceback__))}"})

    # ── Method implementations ────────────────────────────────────────────────

    def _start_kernel(self, params: dict) -> dict:
        jc = _import_jupyter()
        kernel_name = params.get("kernel_name", "python3")

        if self.kc is not None:
            self.kc.stop_channels()
        if self.km is not None:
            self.km.shutdown_kernel(now=True)

        self.km = jc.KernelManager(kernel_name=kernel_name)
        self.km.start_kernel()
        self.kc = self.km.client()
        self.kc.start_channels()
        self.kc.wait_for_ready(timeout=30)
        log("info", f"Kernel '{kernel_name}' started")
        return {"status": "ok", "kernel_name": kernel_name}

    def _connect(self, params: dict) -> dict:
        jc = _import_jupyter()
        cf = params.get("connection_file", "")
        if not cf:
            raise ValueError("connection_file is required")

        if self.kc is not None:
            self.kc.stop_channels()

        self.km = jc.KernelManager(connection_file=cf)
        self.km.load_connection_file()
        self.kc = self.km.client()
        self.kc.start_channels()
        self.kc.wait_for_ready(timeout=10)
        log("info", f"Connected to kernel via {cf}")
        return {"status": "ok", "connection_file": cf}

    def _execute(self, params: dict) -> dict:
        if self.kc is None:
            raise RuntimeError("No kernel connected. Call start_kernel or connect first.")
        code    = params.get("code", "")
        cell_id = params.get("cell_id", "")
        msg_id  = self.kc.execute(code, store_history=True)
        self.msg_to_cell[msg_id] = cell_id
        return {"status": "ok", "msg_id": msg_id}

    def _complete(self, params: dict) -> dict:
        if self.kc is None:
            raise RuntimeError("No kernel connected.")
        code       = params.get("code", "")
        cursor_pos = params.get("cursor_pos", len(code))
        msg_id     = self.kc.complete(code, cursor_pos)
        # Synchronously wait for completion reply (short timeout)
        try:
            reply = self.kc.get_shell_msg(timeout=5)
            content = reply.get("content", {})
            return {
                "matches":      content.get("matches", []),
                "cursor_start": content.get("cursor_start", cursor_pos),
                "cursor_end":   content.get("cursor_end", cursor_pos),
                "metadata":     content.get("metadata", {}),
            }
        except Exception:
            return {"matches": [], "cursor_start": cursor_pos, "cursor_end": cursor_pos}

    def _interrupt(self) -> dict:
        if self.km is None:
            raise RuntimeError("No kernel running.")
        self.km.interrupt_kernel()
        return {"status": "ok"}

    def _restart(self) -> dict:
        if self.km is None:
            raise RuntimeError("No kernel running.")
        self.km.restart_kernel(now=True)
        self.kc.wait_for_ready(timeout=30)
        log("info", "Kernel restarted")
        return {"status": "ok"}

    def _kernel_info(self) -> dict:
        if self.kc is None:
            raise RuntimeError("No kernel connected.")
        msg_id = self.kc.kernel_info()
        reply  = self.kc.get_shell_msg(timeout=5)
        info   = reply.get("content", {})
        return {
            "language": info.get("language_info", {}).get("name", "unknown"),
            "implementation": info.get("implementation", "unknown"),
            "version": info.get("implementation_version", ""),
            "banner": info.get("banner", ""),
        }

    def _list_kernels(self) -> dict:
        jc = _import_jupyter()
        specs = jc.kernelspec.KernelSpecManager().get_all_specs()
        return {"kernels": list(specs.keys())}

    def _shutdown(self) -> dict:
        if self.kc:
            self.kc.stop_channels()
            self.kc = None
        if self.km:
            self.km.shutdown_kernel(now=True)
            self.km = None
        self.running = False
        return {"status": "ok"}

    # ── Kernel message polling ─────────────────────────────────────────────────

    def _poll_kernel(self):
        self._drain_iopub()
        self._drain_shell()

    def _drain_iopub(self):
        while True:
            try:
                msg = self.kc.get_iopub_msg(timeout=0)
                self._handle_iopub(msg)
            except Exception:
                break

    def _drain_shell(self):
        while True:
            try:
                msg = self.kc.get_shell_msg(timeout=0)
                self._handle_shell(msg)
            except Exception:
                break

    def _handle_iopub(self, msg: dict):
        msg_type  = msg.get("msg_type", "")
        parent_id = msg.get("parent_header", {}).get("msg_id", "")
        cell_id   = self.msg_to_cell.get(parent_id, "")
        content   = msg.get("content", {})

        if msg_type == "stream":
            send({
                "type":    "output",
                "cell_id": cell_id,
                "output": {
                    "output_type": "stream",
                    "name":        content.get("name", "stdout"),
                    "text":        content.get("text", ""),
                },
            })

        elif msg_type in ("execute_result", "display_data"):
            send({
                "type":    "output",
                "cell_id": cell_id,
                "output": {
                    "output_type":     msg_type,
                    "execution_count": content.get("execution_count"),
                    "data":            content.get("data", {}),
                    "metadata":        content.get("metadata", {}),
                },
            })

        elif msg_type == "error":
            send({
                "type":    "output",
                "cell_id": cell_id,
                "output": {
                    "output_type": "error",
                    "ename":       content.get("ename", "Error"),
                    "evalue":      content.get("evalue", ""),
                    "traceback":   content.get("traceback", []),
                },
            })

        elif msg_type == "status":
            send({
                "type":            "status",
                "cell_id":         cell_id,
                "execution_state": content.get("execution_state", ""),
            })

        elif msg_type == "execute_input":
            send({
                "type":    "execution_count",
                "cell_id": cell_id,
                "count":   content.get("execution_count"),
            })

    def _handle_shell(self, msg: dict):
        msg_type  = msg.get("msg_type", "")
        parent_id = msg.get("parent_header", {}).get("msg_id", "")
        cell_id   = self.msg_to_cell.get(parent_id, "")
        content   = msg.get("content", {})

        if msg_type == "execute_reply":
            send({
                "type":    "done",
                "cell_id": cell_id,
                "status":  content.get("status", "ok"),
            })
            self.msg_to_cell.pop(parent_id, None)

        elif msg_type == "complete_reply":
            pass  # handled synchronously in _complete


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Ensure stdout/stderr are line-buffered (important for pipe communication)
    sys.stdout = open(sys.stdout.fileno(), mode="w", buffering=1, closefd=False)
    sys.stderr = open(sys.stderr.fileno(), mode="w", buffering=1, closefd=False)

    bridge = KernelBridge()
    try:
        bridge.run()
    except KeyboardInterrupt:
        pass
    except Exception as e:
        log("error", f"Bridge crashed: {e}\n{''.join(tb_mod.format_tb(e.__traceback__))}")
        sys.exit(1)
