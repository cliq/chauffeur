#!/usr/bin/env python3
"""A scripted stand-in for the Anthropic Messages API, for running the real Claude
Code TUI with no account and no paid inference. Import `serve(decide)` or run it
directly for a probe that answers every turn with a fixed reply.

Point a throwaway CLAUDE_CONFIG_DIR at it with `profile(directory, port)`, which
writes settings.json (ANTHROPIC_BASE_URL, a fixture API key, permissions) and a
.claude.json that skips onboarding.

`decide(body)` returns (delay_seconds, blocks), where blocks is a list of
{'type':'text','text':…} or {'type':'tool_use','name':…,'input':{…}}.
"""
import http.server, json, pathlib, threading, time, uuid

FIXTURE_KEY = 'sk-ant-api03-chauffeur-mock-fixture-key-0000000000000000000000AA'

def profile(directory, port, allow=(), trusted=()):
    directory = pathlib.Path(directory); directory.mkdir(parents=True, exist_ok=True)
    (directory / 'settings.json').write_text(json.dumps({
        'env': {'ANTHROPIC_BASE_URL': f'http://127.0.0.1:{port}', 'ANTHROPIC_API_KEY': FIXTURE_KEY,
                'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'DISABLE_AUTOUPDATER': '1'},
        'permissions': {'allow': list(allow)}, 'model': 'claude-haiku-4-5-20251001'}))
    (directory / '.claude.json').write_text(json.dumps({
        'hasCompletedOnboarding': True, 'theme': 'dark', 'bypassPermissionsModeAccepted': True,
        'customApiKeyResponses': {'approved': [FIXTURE_KEY[-20:]], 'rejected': []},
        'projects': {str(pathlib.Path(path).resolve()): {'hasTrustDialogAccepted': True, 'hasCompletedProjectOnboarding': True} for path in trusted}}))

def events(blocks, model):
    message_id = 'msg_' + uuid.uuid4().hex[:12]
    yield 'message_start', {'type': 'message_start', 'message': {'id': message_id, 'type': 'message', 'role': 'assistant', 'model': model, 'content': [], 'stop_reason': None, 'stop_sequence': None, 'usage': {'input_tokens': 1, 'output_tokens': 1}}}
    for index, block in enumerate(blocks):
        if block['type'] == 'text':
            yield 'content_block_start', {'type': 'content_block_start', 'index': index, 'content_block': {'type': 'text', 'text': ''}}
            yield 'content_block_delta', {'type': 'content_block_delta', 'index': index, 'delta': {'type': 'text_delta', 'text': block['text']}}
        else:
            yield 'content_block_start', {'type': 'content_block_start', 'index': index, 'content_block': {'type': 'tool_use', 'id': 'toolu_' + uuid.uuid4().hex[:20], 'name': block['name'], 'input': {}}}
            yield 'content_block_delta', {'type': 'content_block_delta', 'index': index, 'delta': {'type': 'input_json_delta', 'partial_json': json.dumps(block['input'])}}
        yield 'content_block_stop', {'type': 'content_block_stop', 'index': index}
    stop = 'tool_use' if any(b['type'] == 'tool_use' for b in blocks) else 'end_turn'
    yield 'message_delta', {'type': 'message_delta', 'delta': {'stop_reason': stop, 'stop_sequence': None}, 'usage': {'output_tokens': 1}}
    yield 'message_stop', {'type': 'message_stop'}

def serve(decide, log=None):
    """Starts the mock on a free port; returns (server, requests list)."""
    requests = []
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def reply(self, code, value):
            data = json.dumps(value).encode()
            self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        def do_GET(self): self.reply(200, {'data': [], 'has_more': False})
        def do_HEAD(self): self.send_response(200); self.end_headers()
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
            path = self.path.split('?')[0]
            if not path.endswith('/v1/messages'):
                return self.reply(200, {'input_tokens': 1} if 'count_tokens' in path else {})
            requests.append(body)
            if log: log.write(json.dumps(body) + '\n'); log.flush()
            delay, blocks = decide(body)
            time.sleep(delay)
            model = body.get('model', 'claude-haiku-4-5-20251001')
            if not body.get('stream'):
                content = [{'type': 'text', 'text': b['text']} if b['type'] == 'text' else {'type': 'tool_use', 'id': 'toolu_' + uuid.uuid4().hex[:20], 'name': b['name'], 'input': b['input']} for b in blocks]
                return self.reply(200, {'id': 'msg_x', 'type': 'message', 'role': 'assistant', 'model': model, 'content': content, 'stop_reason': 'end_turn', 'stop_sequence': None, 'usage': {'input_tokens': 1, 'output_tokens': 1}})
            out = ''.join(f'event: {name}\ndata: {json.dumps(data)}\n\n' for name, data in events(blocks, model)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, requests

if __name__ == '__main__':
    import sys
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/clm')
    root.mkdir(parents=True, exist_ok=True)
    server, _ = serve(lambda body: (0, [{'type': 'text', 'text': 'MOCK_REPLY'}]), log=(root / 'requests.jsonl').open('a'))
    profile(root / 'config', server.server_port, trusted=[root / 'work'])
    (root / 'work').mkdir(exist_ok=True)
    print(server.server_port, flush=True)
    threading.Event().wait()
