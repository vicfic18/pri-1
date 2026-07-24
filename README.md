# Hold-to-record audio CLI

This project provides a small Python CLI that records microphone audio while a chosen key is held down and saves the result as a WAV file.

## Usage

Run it from the project root:

```bash
python main.py --key space --output capture.wav
```

Options:
- `--key`: the key to watch for (for example `space`, `a`, `enter`)
- `--output`: the output WAV path
- `--sample-rate`: the recording sample rate in Hz

Press and hold the selected key to start recording, then release it to stop and save the audio.
