import glob
import json
import os
import re
import sys
from urllib.parse import unquote, urlparse


def uri_to_path(uri):
    parsed = urlparse(uri)
    if parsed.scheme != "file":
        return None
    path = unquote(parsed.path)
    if os.name == "nt" and re.match(r"^/[A-Za-z]:", path):
        path = path[1:]
    return os.path.realpath(path)


def storage_roots():
    home = os.path.expanduser("~")
    roots = [
        os.path.join(home, ".config", "Code*", "User", "workspaceStorage"),
        os.path.join(home, ".config", "VSCodium", "User", "workspaceStorage"),
        os.path.join(home, "snap", "code", "common", ".config", "Code", "User", "workspaceStorage"),
        os.path.join(home, "Library", "Application Support", "Code*", "User", "workspaceStorage"),
    ]
    appdata = os.environ.get("APPDATA")
    if appdata:
        roots.append(os.path.join(appdata, "Code*", "User", "workspaceStorage"))
    files = []
    for root in roots:
        files.extend(glob.glob(os.path.join(root, "*", "workspace.json")))
    return files


def workspace_folders(ws_file):
    try:
        text = open(ws_file, encoding="utf-8").read()
    except OSError:
        return []
    cleaned = re.sub(r"//[^\n]*", "", text)
    cleaned = re.sub(r",\s*([}\]])", r"\1", cleaned)
    paths = []
    try:
        data = json.loads(cleaned)
        for folder in data.get("folders", []):
            if isinstance(folder, dict) and folder.get("path"):
                paths.append(folder["path"])
            elif isinstance(folder, dict) and folder.get("uri"):
                converted = uri_to_path(folder["uri"])
                if converted:
                    paths.append(converted)
    except ValueError:
        paths = re.findall(r'"path"\s*:\s*"([^"]+)"', text)
    base = os.path.dirname(ws_file)
    return [os.path.realpath(os.path.join(base, os.path.expanduser(p))) for p in paths]


def contains(folder, cwd):
    folder = folder.rstrip(os.sep)
    return cwd == folder or cwd.startswith(folder + os.sep)


def open_window_titles():
    import subprocess
    for cmd in (["wmctrl", "-l"], ["xdotool", "search", "--name", "Visual Studio Code", "getwindowname", "%@"]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=2).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        if out:
            lines = [l for l in out.splitlines() if re.search(r"Visual Studio Code|VSCodium|Code - OSS", l)]
            return "\n".join(lines)
    return ""


def encode_project_key(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def is_origin(folder, project_key):
    if not project_key:
        return False
    encoded = encode_project_key(folder.rstrip(os.sep))
    return project_key == encoded or project_key.startswith(encoded + "-")


def main():
    cwd = sys.argv[1] if len(sys.argv) > 1 else ""
    project_key = sys.argv[2] if len(sys.argv) > 2 else ""
    if not cwd:
        print("null")
        return
    cwd = os.path.realpath(cwd)
    fallback = {"hint": os.path.basename(cwd), "label": os.path.basename(cwd), "workspaceFile": None}
    candidates = []
    for storage in storage_roots():
        try:
            meta = json.load(open(storage, encoding="utf-8"))
            mtime = os.path.getmtime(storage)
        except (OSError, ValueError):
            continue
        if meta.get("workspace"):
            ws_file = uri_to_path(meta["workspace"])
            if not ws_file or not os.path.exists(ws_file):
                continue
            folders = workspace_folders(ws_file)
            hint = re.sub(r"\.code-workspace$", "", os.path.basename(ws_file))
            kind = "workspace"
        elif meta.get("folder"):
            ws_file = None
            folder = uri_to_path(meta["folder"])
            if not folder:
                continue
            folders = [folder]
            hint = os.path.basename(folder)
            kind = "folder"
        else:
            continue
        for folder in folders:
            origin = is_origin(folder, project_key)
            if origin or contains(folder, cwd):
                candidates.append({"origin": origin, "len": len(folder), "mtime": mtime, "hint": hint, "kind": kind, "workspaceFile": ws_file})
    if not candidates:
        print(json.dumps(fallback))
        return
    titles = open_window_titles()

    def visible(c):
        if not titles:
            return False
        if c["kind"] == "workspace":
            return f"{c['hint']} (Workspace)" in titles
        return f" - {c['hint']} - " in titles

    best = max(candidates, key=lambda c: (c["origin"], visible(c), c["len"], c["mtime"]))
    print(json.dumps({"hint": best["hint"], "label": best["hint"], "workspaceFile": best["workspaceFile"]}))


if __name__ == "__main__":
    main()
