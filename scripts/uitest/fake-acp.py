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
for line in sys.stdin:
    m = json.loads(line); meth = m.get("method"); p = m.get("params", {})
    if "id" not in m or meth is None: continue
    if meth == "initialize":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True, "sessionCapabilities": {"list": {}, "close": {}}}}})
    elif meth == "session/new":
        count[0] += 1
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "agent-%d-%d" % (os.getpid(), count[0]), "configOptions": options}})
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
        plan(sid, True)
        text(sid, "agent_message_chunk", "Stand-in reply.")
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
    else:
        send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "not offered"}})
