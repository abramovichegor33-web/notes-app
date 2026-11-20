import socket
import ssl
import json
import base64
import os

host = 'fvkbsnzvluhnxsbzeivy.supabase.co'
port = 443
apikey = 'sb_publishable_Wv1HBMHDBJFkIfwOjCi89A_OMXEQvnS'
path = f'/realtime/v1/websocket?apikey={apikey}&vsn=1.0.0'

context = ssl.create_default_context()
with socket.create_connection((host, port)) as sock:
    with context.wrap_socket(sock, server_hostname=host) as ssock:
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n"
        )
        ssock.sendall(req.encode())
        res = ssock.recv(4096)
        print("Handshake response:\n", res.decode('utf-8', errors='ignore')[:300])
