import evdev
from evdev import InputDevice, categorize, ecodes
import sounddevice as sd
import numpy as np
import queue
import wave
from scipy.signal import resample

import nemo.collections.asr as nemo_asr
from nemo.utils import logging


## AUdio stuff

keyboard_path = '/dev/input/event4'
dev = InputDevice(keyboard_path)

pressed_keys = set()
target_combination = {'KEY_LEFTSHIFT', 'KEY_LEFTMETA', 'KEY_F23'}
combination_active = False

NATIVE_RATE = 44100
TARGET_RATE = 16000
CHANNELS = 1
OUTPUT_PATH = '/tmp/recording.wav'

audio_queue = queue.Queue()
recording_stream = None

def audio_callback(indata, frames, time_info, status):
    if status:
        print(status, flush=True)
    audio_queue.put(indata.copy())

def start_recording():
    global recording_stream
    print(f"Pressed: {' + '.join(target_combination)} -> Starting recording...")
    while not audio_queue.empty():
        audio_queue.get_nowait()
    
    recording_stream = sd.InputStream(
        samplerate=NATIVE_RATE, 
        channels=CHANNELS, 
        callback=audio_callback,
        dtype='int16'
    )
    recording_stream.start()

def stop_recording():
    global recording_stream
    if recording_stream:
        recording_stream.stop()
        recording_stream.close()
        recording_stream = None

    print(f"Released: {' + '.join(target_combination)} -> Processing and saving...")
    
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
        print(f"Saved 16kHz audio to {OUTPUT_PATH}")
    else:
        print("No audio recorded.")

### MAIN STUFF

logging.setLevel(logging.ERROR)

print("Loading the audio model")
asr_model = nemo_asr.models.ASRModel.from_pretrained(model_name="nvidia/parakeet-tdt-0.6b-v3")

print(f"Listening on {dev.name} ({dev.path})...")

# main loop
try:
    for event in dev.read_loop():
        if event.type == ecodes.EV_KEY:
            data = categorize(event)
            keycode = data.keycode
            if isinstance(keycode, list):
                keycode = keycode[0]

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
                # after recording
                output = asr_model.transcribe(['2086-149220-0033.wav'])
                print(output[0].text)
                
except KeyboardInterrupt:
    stop_recording()
    print("Exiting...")