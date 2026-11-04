#!/usr/bin/env python3
"""Turn a raw Claude or Codex CLI recording into a fixture that is safe to commit.

Keeps protocol shape and drops anything describing the machine or account: frames
that list skills, plugins, servers or accounts are reduced to an allowlist, ids are
replaced consistently and paths are rewritten. Review the output and run
`make privacy` before committing.

Usage: sanitize-agent-recording.py INPUT.jsonl OUTPUT.jsonl --cwd RECORDED_CWD
"""
import argparse
import json
import os
import re

UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I)
PREFIXED_ID = re.compile(r"\b(toolu|msg|req|call|srvtoolu|exec|item|fc|rs)[_-][A-Za-z0-9_-]{8,}\b")
HOME_PATH = re.compile(r"(?:/Users|/home)/[^\s\"']+|/private/[^\s\"']+|/var/folders/[^\s\"']+")
EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
DROP_KEYS = {"signature", "encrypted_content", "memory_paths", "messaging_socket_path", "account",
             "commands", "skills", "plugins", "mcp_servers", "agents", "slash_commands",
             "terminal_slash_commands", "instructions", "instructionSources", "userAgent",
             "gitInfo", "codexHome", "path", "sourceId", "forkedFromId", "api-request-shape"}
CLAUDE_INIT_KEYS = {"type", "subtype", "session_id", "uuid", "model", "permissionMode", "apiKeySource",
                    "cwd", "tools", "claude_code_version"}
CODEX_DROP_METHODS = ("mcpServer/", "remoteControl/", "account/", "skills/", "configWarning", "app/")


class Sanitizer:
    def __init__(self, cwd):
        self.cwd = cwd
        self.ids = {}

    def _id(self, match):
        value = match.group(0)
        if value not in self.ids:
            self.ids[value] = f"00000000-0000-4000-8000-{len(self.ids) + 1:012d}"
        return self.ids[value]

    def text(self, value):
        value = value.replace(self.cwd, "/tmp/project")
        value = HOME_PATH.sub("/tmp/redacted", value)
        value = EMAIL.sub("person@example.org", value)
        value = UUID.sub(self._id, value)
        return PREFIXED_ID.sub(self._id, value)

    def walk(self, value):
        if isinstance(value, dict):
            return {key: self.walk(item) for key, item in value.items() if key not in DROP_KEYS}
        if isinstance(value, list):
            return [self.walk(item) for item in value]
        return self.text(value) if isinstance(value, str) else value

    def frame(self, data):
        kind = data.get("type")
        method = data.get("method", "")
        if method.startswith(CODEX_DROP_METHODS):
            return None
        if kind == "system" and data.get("subtype") == "init":
            data = {key: value for key, value in data.items() if key in CLAUDE_INIT_KEYS}
            data["tools"] = [tool for tool in data.get("tools", []) if not tool.startswith("mcp__")]
        if kind == "control_response" and isinstance(data["response"].get("response"), dict):
            reply = data["response"]["response"]
            if "models" in reply:
                data["response"]["response"] = {"models": [{"value": model.get("value")} for model in reply["models"]],
                                                "current_permission_mode": reply.get("current_permission_mode")}
        if "result" in data and "id" in data and isinstance(data["result"], dict):
            result = data["result"]
            if "thread" in result:
                thread = result["thread"]
                data["result"] = {"thread": {"id": thread.get("id")}, "model": result.get("model")}
            elif "userAgent" in result or "codexHome" in result:
                data["result"] = {}
        return self.walk(data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("output")
    parser.add_argument("--cwd", required=True)
    args = parser.parse_args()
    sanitizer = Sanitizer(os.path.realpath(args.cwd))
    with open(args.input) as source, open(args.output, "w") as target:
        for line in source:
            sent = line.startswith("# SENT ")
            data = json.loads(line[7:] if sent else line)
            clean = sanitizer.frame(data)
            if clean is not None:
                target.write(("# SENT " if sent else "") + json.dumps(clean, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
