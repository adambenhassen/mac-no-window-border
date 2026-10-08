import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import noborder  # noqa: E402
from noborder import AppsHelper  # noqa: E402

# Stand-ins for `noborder.py --apps-helper`. Each answers with the request it got.
ECHO = """import sys
for line in sys.stdin:
    print("log line", flush=True)
    print("= got " + line.strip(), flush=True)
"""
ONE_THEN_EXIT = """import sys
print("= got " + sys.stdin.readline().strip(), flush=True)
"""
CRASH_ON_REQUEST = """import os, sys
sys.stdin.readline()
os._exit(3)
"""


def helper(code, **kw):
    return AppsHelper(cmd=[sys.executable, "-c", code], **kw)


class AppsHelperTest(unittest.TestCase):
    def setUp(self):
        self.emitted = []
        patcher = mock.patch.object(noborder, "emit", self.emitted.append)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_sends_request_returns_result_and_forwards_logs(self):
        h = helper(ECHO)
        self.addCleanup(h.stop)
        self.assertEqual(h.apply(42, [7, 8]), "got apply 42 7 8")
        self.assertEqual(h.restore(42, [7]), "got restore 42 7")
        self.assertEqual(self.emitted, ["log line", "log line"])

    def test_reuses_one_child_across_calls(self):
        h = helper(ECHO)
        self.addCleanup(h.stop)
        h.apply(1, [1])
        first = h.proc.pid
        h.apply(1, [1])
        self.assertEqual(h.proc.pid, first)

    def test_child_death_during_call_fails_then_respawns(self):
        h = helper(CRASH_ON_REQUEST)
        self.assertEqual(h.apply(1, [1]), "failed")
        self.assertIsNone(h.proc)
        self.assertEqual(h.apply(1, [1]), "failed")  # a fresh child got the request
        self.assertIn("code 3", self.emitted[-1])

    def test_child_that_died_while_idle_is_replaced_without_failing(self):
        h = helper(ONE_THEN_EXIT)
        self.addCleanup(h.stop)
        self.assertEqual(h.apply(1, [1]), "got apply 1 1")
        h.proc.wait()
        self.assertEqual(h.apply(2, [2]), "got apply 2 2")

    def test_stop_if_idle_waits_for_idle_time(self):
        h = helper(ECHO, idle_s=60)
        self.addCleanup(h.stop)
        h.apply(1, [1])
        proc = h.proc
        with mock.patch.object(noborder.time, "monotonic", return_value=h.last_used + 59):
            h.stop_if_idle()
        self.assertIs(h.proc, proc)
        with mock.patch.object(noborder.time, "monotonic", return_value=h.last_used + 60):
            h.stop_if_idle()
        self.assertIsNone(h.proc)
        self.assertEqual(proc.returncode, 0)  # exited at EOF, not killed

    def test_stop_without_child_is_a_no_op(self):
        helper(ECHO).stop()


if __name__ == "__main__":
    unittest.main()
