# A stand-in for Claude Code's ACP adapter, for UI checks (never the owner's real agent). It
# lists the chats fake `claude` is running (their <config>/sessions files) and one older chat,
# replays any chat it's asked to load, and answers prompts with a line and a plan.
#
#   python3 fake-acp.py <claude config dir>
import json, os, sys, glob, time

config = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.claude")
def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
def up(sid, u): send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": u}})
def text(sid, kind, t): up(sid, {"sessionUpdate": kind, "content": {"type": "text", "text": t}})
def plan(sid, done):
    up(sid, {"sessionUpdate": "plan", "entries": [
        {"content": "Read the pill", "status": "completed", "priority": "high"},
        {"content": "Fix its width", "status": "completed" if done else "in_progress", "priority": "high"},
        {"content": "Check it on screen", "status": "pending", "priority": "medium"}]})
options = [{"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "standin",
            "options": [{"value": "standin", "name": "Stand-in"}]}]
count = [0]
folders = {}
for line in sys.stdin:
    m = json.loads(line); meth = m.get("method"); p = m.get("params", {})
    if "id" not in m or meth is None: continue
    if meth == "initialize":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True, "sessionCapabilities": {"list": {}, "close": {}}}}})
    elif meth == "session/new":
        count[0] += 1
        sid = "agent-%d-%d" % (os.getpid(), count[0])
        folders[sid] = p.get("cwd")
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": sid, "configOptions": options}})
    elif meth == "session/list":
        sessions = [{"sessionId": "earlier-chat", "cwd": p.get("cwd"), "title": "Earlier chat about the docs", "updatedAt": "2026-11-01T09:00:00.000Z"}]
        for path in glob.glob(os.path.join(config, "sessions", "*.json")):
            try:
                record = json.load(open(path)); sid = record["sessionId"]
                os.kill(record["pid"], 0)  # a fake claude that's gone left its file behind
            except Exception: continue
            sessions.append({"sessionId": sid, "cwd": p.get("cwd"), "title": "Fix the pill's width", "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(os.path.getmtime(path)))})
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessions": sessions}})
    elif meth == "session/load":
        sid = p["sessionId"]
        folders[sid] = p.get("cwd")
        text(sid, "user_message_chunk", "The track pill is too wide. Fix its width.")
        text(sid, "agent_thought_chunk", "Looking at TrackPill.swift")
        up(sid, {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read TrackPill.swift", "kind": "read", "status": "completed"})
        plan(sid, False)
        text(sid, "agent_message_chunk", "The pill measured its title twice. I've made it measure once.")
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"configOptions": options}})
    elif meth == "session/close":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {}})
    elif meth == "session/prompt":
        sid = p["sessionId"]
        said = "".join(block.get("text", "") for block in p.get("prompt", []))
        if "FAIL" in said:
            send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32000, "message": "The stand-in failed on purpose."}})
            continue
        if "LONG" in said:
            text(sid, "agent_message_chunk", "\n\n".join("Paragraph %d of a long answer, so the conversation scrolls." % i for i in range(40)))
            send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
            continue
        # Changes a file in the session's folder, as an agent's turn does: a checkpoint follows.
        if folders.get(sid):
            with open(os.path.join(folders[sid], "NOTES.md"), "a") as f: f.write("# Notes\n\nThe pill measures once.\n")
        plan(sid, True)
        text(sid, "agent_message_chunk", "Stand-in reply.")
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
    else:
        send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "not offered"}})
