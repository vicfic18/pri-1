import os
import socket
import sys
import signal

import nemo.collections.asr as nemo_asr
from nemo.utils import logging

from LanguageModel import single_ask

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


# Helper functions

def llm_call(ask: str):
    print("Asked LLM here.")
    # single_ask(ask)


# MAIN

print("[Server] Loading ASR model...")
asr_model = nemo_asr.models.ASRModel.from_pretrained(model_name="nvidia/parakeet-tdt-0.6b-v3")

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

            elif data and os.path.exists(data):
                print(f"[Server] Transcribing: {data}")
                output = asr_model.transcribe([data])
                text = output[0].text
                print(f"[Server] Result: {text}")
                # conn.sendall(text.encode('utf-8'))

                llm_call(text)

finally:
    print("[Server] Closing server socket...")
    server.close()
    cleanup_socket()
    print("[Server] Stopped.")