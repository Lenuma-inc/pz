"""Deterministic live debate through the production swarm tool."""
import json
import sys

req = json.load(sys.stdin)
parts = [part for msg in req["msgs"] for part in msg["parts"]]
texts = "\n".join(p["text"] for p in parts if p["type"] == "text")
results = {}
for part in parts:
    if part["type"] == "tool_result":
        assert not part["is_err"], part
        results[part["id"]] = json.loads(part["out"].removeprefix("stdout:\n"))

assert req["model"] == "test-model", req["model"]
assert req["opts"]["thinking"] == "budget", req["opts"]
assert req["opts"]["thinking_budget"] == 16384, req["opts"]


def call(call_id, op, **args):
    print("tool_call:" + call_id + "|swarm|" + json.dumps(dict(op=op, **args)))
    print("stop:tool")


if "SWARM_PARENT" in texts:
    steps = [
        ("p1", "spawn", dict(id="author", prompt="WORK_A")),
        ("p2", "spawn", dict(id="critic", prompt="WORK_B")),
        ("p3", "send", dict(id="author", text="START")),
        ("p4", "send", dict(id="critic", text="START")),
        ("p5", "wait", dict(id="author", timeout_ms=10000)),
        ("p6", "wait", dict(id="critic", timeout_ms=10000)),
    ]
    for call_id, op, args in steps:
        if call_id not in results:
            call(call_id, op, **args)
            break
    else:
        a, b = results["p5"], results["p6"]
        assert a["state"] == b["state"] == "done", (a, b)
        assert a["text"].strip() == "A_REVISED_42", a
        assert b["text"].strip() == "B_ACCEPTED_42", b
        assert a["started_ms"] <= b["ended_ms"]
        assert b["started_ms"] <= a["ended_ms"]
        print("text:SWARM_COMPLETE")
        print("stop:done")
else:
    messages = [m for value in results.values() for m in value.get("messages", [])]

    def received(sender, text):
        return any(
            m["from"] == sender and m["text"] == text for m in messages
        )

    def recv():
        call("recv" + str(len(results)), "recv", timeout_ms=10000)

    if not received("parent", "START"):
        recv()
    elif "WORK_A" in texts:
        if "proposal" not in results:
            call("proposal", "send", id="critic", text="proposal=41")
        elif not received("critic", "objection: answer=42"):
            recv()
        elif "revision" not in results:
            call("revision", "send", id="critic", text="revision=42")
        elif not received("critic", "accepted=42"):
            recv()
        else:
            print("text:A_REVISED_42\nstop:done")
    elif "WORK_B" in texts:
        if not received("author", "proposal=41"):
            recv()
        elif "objection" not in results:
            call("objection", "send", id="author", text="objection: answer=42")
        elif not received("author", "revision=42"):
            recv()
        elif "accept" not in results:
            call("accept", "send", id="author", text="accepted=42")
        else:
            print("text:B_ACCEPTED_42\nstop:done")
    else:
        raise AssertionError("unknown participant")
