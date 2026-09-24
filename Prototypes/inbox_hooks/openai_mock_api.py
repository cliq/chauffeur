#!/usr/bin/env python3
"""A scripted stand-in for an OpenAI-compatible Chat Completions server, for running
the real OpenCode TUI (through `@ai-sdk/openai-compatible`) with no account and no
paid inference. Import `serve(decide)` or run it directly for a probe that answers
every turn with a fixed reply.

`opencode_config(port)` returns the `provider` block (provider `mock`, model
`mock/mock-model`) to put in an isolated `$XDG_CONFIG_HOME/opencode/opencode.json`.

`decide(body)` returns (delay_seconds, items), where items is a list of
{'type':'text','text':…} or {'type':'tool','name':…,'input':{…}}. Replies always
stream (SSE chunks, then `data: [DONE]`), as OpenCode requests them.
"""
import http.server, json, threading, time, uuid

MODEL = 'mock-model'

def opencode_config(port):
    return {'mock': {'npm': '@ai-sdk/openai-compatible', 'name': 'Local mock',
                     'options': {'baseURL': f'http://127.0.0.1:{port}/v1', 'apiKey': 'mock-fixture-key'},
                     'models': {MODEL: {'name': 'Mock model', 'tool_call': True, 'limit': {'context': 32768, 'output': 4096}}}}}

def text_of(message):
    """The plain text of a chat message whose content is a string or a list of parts."""
    content = message.get('content')
    if isinstance(content, str): return content
    if isinstance(content, list): return ''.join(p.get('text', '') for p in content if isinstance(p, dict))
    return ''

def chunks(items, model):
    base = {'id': 'chatcmpl-' + uuid.uuid4().hex[:12], 'object': 'chat.completion.chunk', 'created': int(time.time()), 'model': model}
    def chunk(delta, finish=None): return {**base, 'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
    yield chunk({'role': 'assistant', 'content': ''})
    calls = 0
    for item in items:
        if item['type'] == 'text':
            yield chunk({'content': item['text']})
        else:
            yield chunk({'tool_calls': [{'index': calls, 'id': 'call_' + uuid.uuid4().hex[:16], 'type': 'function',
                                         'function': {'name': item['name'], 'arguments': json.dumps(item['input'])}}]})
            calls += 1
    yield chunk({}, 'tool_calls' if calls else 'stop')
    yield {**base, 'choices': [], 'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}}

def serve(decide, log=None):
    """Starts the mock on a free port; returns (server, requests list)."""
    requests = []
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *a): pass
        def reply(self, code, value):
            data = json.dumps(value).encode()
            self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        def do_GET(self): self.reply(200, {'object': 'list', 'data': [{'id': MODEL, 'object': 'model', 'owned_by': 'mock'}]})
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
            if not self.path.split('?')[0].endswith('/chat/completions'): return self.reply(404, {'error': {'message': 'not found'}})
            requests.append(body)
            if log: log.write(json.dumps(body) + '\n'); log.flush()
            delay, items = decide(body)
            time.sleep(delay)
            model = body.get('model', MODEL)
            if not body.get('stream'):
                calls = [{'id': 'call_' + uuid.uuid4().hex[:16], 'type': 'function', 'function': {'name': i['name'], 'arguments': json.dumps(i['input'])}} for i in items if i['type'] != 'text']
                message = {'role': 'assistant', 'content': ''.join(i['text'] for i in items if i['type'] == 'text') or None, **({'tool_calls': calls} if calls else {})}
                return self.reply(200, {'id': 'chatcmpl-x', 'object': 'chat.completion', 'created': int(time.time()), 'model': model,
                                        'choices': [{'index': 0, 'message': message, 'finish_reason': 'tool_calls' if calls else 'stop'}],
                                        'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}})
            out = (''.join(f'data: {json.dumps(c)}\n\n' for c in chunks(items, model)) + 'data: [DONE]\n\n').encode()
            self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Cache-Control', 'no-cache')
            self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, requests

if __name__ == '__main__':
    import pathlib, sys
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/oam')
    root.mkdir(parents=True, exist_ok=True)
    server, _ = serve(lambda body: (0, [{'type': 'text', 'text': 'MOCK_REPLY'}]), log=(root / 'requests.jsonl').open('a'))
    print(server.server_port, flush=True)
    threading.Event().wait()
