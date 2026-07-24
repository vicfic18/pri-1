import os
import socket
import sys
import signal

import nemo.collections.asr as nemo_asr
from nemo.utils import logging

SOCKET_PATH = "/tmp/asr_service.sock"
logging.setLevel(logging.ERROR)

# Handling the running
running = True
def handle_shutdown(signum, frame):
    global running
    print(f"\n[Server] Received signal {signum}. Initiating graceful shutdown...")
    running = False

signal.signal(signal.SIGINT, handle_shutdown)
signal.signal(signal.SIGTERM, handle_shutdown)

def cleanup_socket():
    if os.path.exists(SOCKET_PATH):
        try:
            os.remove(SOCKET_PATH)
            print("[Server] Socket file cleaned up.")
        except OSError as e:
            print(f"[Server] Error removing socket file: {e}")

cleanup_socket()

# MAIN

print("[Server] Loading ASR model...")
asr_model = nemo_asr.models.ASRModel.from_pretrained(model_name="nvidia/parakeet-tdt-0.6b-v3")

# 1. Fix warning 1: Disable pretokenize to avoid main process sampling warnings
if hasattr(asr_model, "_cfg") and "test_ds" in asr_model._cfg:
    with open_dict(asr_model._cfg.test_ds):
        asr_model._cfg.test_ds.pretokenize = False


server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(SOCKET_PATH)
server.listen(1)
# 1.0 second timeout allows checking the `running` flag periodically
server.settimeout(1.0) 

print(f"[Server] Ready and listening on {SOCKET_PATH}...")

try:
    while running:
        try:
            conn, _ = server.accept()
        except socket.timeout:
            continue  # Periodically unblocks to check the `running` flag

        with conn:
            data = conn.recv(1024).decode('utf-8').strip()
            
            # Control Protocol: Shutdown command from client
            if data == "SHUTDOWN":
                print("[Server] Received SHUTDOWN command from client.")
                running = False
                conn.sendall(b"OK_SHUTDOWN")
                break

            # Application Logic: Transcribe audio
            elif data and os.path.exists(data):
                print(f"[Server] Transcribing: {data}")
                output = asr_model.transcribe([data])
                text = output[0].text
                print(f"[Server] Result: {text}")
                conn.sendall(text.encode('utf-8'))

finally:
    print("[Server] Closing server socket...")
    server.close()
    cleanup_socket()
    print("[Server] Stopped.")