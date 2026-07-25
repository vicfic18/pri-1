import os
import queue
import socket
import wave
import evdev
from evdev import InputDevice, categorize, ecodes
import numpy as np
import sounddevice as sd
from scipy.signal import resample

# CONFIG
ASR_SOCKET_PATH = "/tmp/asr_service.sock"
RIPPLE_SOCKET_PATH = "/tmp/gnome_ripple.sock"

OUTPUT_PATH = '/tmp/recording.wav'
keyboard_path = '/dev/input/event4'
NATIVE_RATE, TARGET_RATE, CHANNELS = 44100, 16000, 1
target_combination = {'KEY_LEFTSHIFT', 'KEY_LEFTMETA', 'KEY_F23'}

dev = InputDevice(keyboard_path)
pressed_keys = set()
combination_active = False
recording_stream = None
audio_queue = queue.Queue()  # queue that holds live data


def send_ripple_command(cmd: str):
    """Sends IPC signal ('START', 'STOP', 'TOGGLE') to GNOME extension socket."""
    if not os.path.exists(RIPPLE_SOCKET_PATH):
        print(f"[Ripple] Socket not found at {RIPPLE_SOCKET_PATH}")
        return

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(RIPPLE_SOCKET_PATH)
            client.sendall(f"{cmd}\n".encode('utf-8'))
    except Exception as e:
        print(f"[Ripple] IPC communication error: {e}")


def audio_callback(indata, frames, time_info, status):
    audio_queue.put(indata.copy())

def start_recording():
    global recording_stream
    print("Recording started...")

    send_ripple_command("START")

    while not audio_queue.empty():
        audio_queue.get_nowait()
    recording_stream = sd.InputStream(
        samplerate=NATIVE_RATE,
        channels=CHANNELS,
        callback=audio_callback,
        dtype='int16',
    )
    recording_stream.start()


def send_to_worker(file_path):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(ASR_SOCKET_PATH)
            client.sendall(file_path.encode('utf-8'))
            response = client.recv(1024).decode('utf-8')
            # print(f"Transcribed Text: {response}")
    except Exception as e:
        print(f"Failed to communicate with worker socket: {e}")


def stop_recording():
    global recording_stream

    # Stop shader visual effect immediately on hotkey release
    send_ripple_command("STOP")

    if recording_stream:
        recording_stream.stop()
        recording_stream.close()
        recording_stream = None

    audio_data = []
    while not audio_queue.empty():
        audio_data.append(audio_queue.get_nowait())

    if audio_data:
        full_audio = np.concatenate(audio_data, axis=0).flatten()
        num_output_samples = int(len(full_audio) * TARGET_RATE / NATIVE_RATE)
        resampled_audio = resample(full_audio, num_output_samples).astype(np.int16)
        
        with wave.open(OUTPUT_PATH, 'wb') as wf:
            wf.setnchannels(CHANNELS)
            wf.setsampwidth(2)
            wf.setframerate(TARGET_RATE)
            wf.writeframes(resampled_audio.tobytes())

        print("Recording stopped.")
        send_to_worker(OUTPUT_PATH)


# MAIN
print(f"Listening for hotkey on {dev.name}...")

try:
    for event in dev.read_loop():
        if event.type == ecodes.EV_KEY:
            data = categorize(event)
            keycode = (
                data.keycode[0]
                if isinstance(data.keycode, list)
                else data.keycode
            )

            if data.keystate == 1:
                pressed_keys.add(keycode)
            elif data.keystate == 0:
                pressed_keys.discard(keycode)

            if not combination_active and target_combination.issubset(pressed_keys):
                combination_active = True
                start_recording()
            elif combination_active and not target_combination.issubset(pressed_keys):
                combination_active = False
                stop_recording()

except KeyboardInterrupt:
    print("Exiting...")