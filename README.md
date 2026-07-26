# PRI-1
ask and you shall receive. (v. alpha)

Personal Requirement Indulgence - One, is an application that does things you tell it to do. It can also be described as an end to end agentic LLM powered AI that integrates well with Linux Desktop environments. This was an impulsive friday evening project that I intend to work more on later.

## Install

Clone the repo. 
```bash
uv install
#for tts download the voice
uv run python3 -m piper.download_voices en_GB-cori-high

# run main program
uv run main.py
```
Open another terminal
```bash
sudo uv run key_daemon.py
```
You need an LLM inference source. I ran `Ternary-Bonsai-8B-Q2_0_g64.gguf` through llama.cpp because it ran at around 150tk/s on my laptop 5070Ti. Try to get a fast one.

I made a GNOME 50 Extension for live OpenGL shader effect when pressing down to record. 

## System Requirements

Recommended: I built this with my laptop in mind, so as of now, the STT, LLM & TTS runs on my 12GB VRAM.

>_OPTIMISATIONS_: I agree this is not optmal, and I intend to offload the STT part onto the NPU for less power usage. I consider TTS as more a gimmick, as I usually prefer reading faster than listening, so turn it off. For LLM, I do intend to use function call finetuned models which can drastically reduce power consumption.

The timing breakdown is also interesting, for the average query:
- STT takes around 60ms
- LLM takes around 300ms
- TTS takes around 2000ms

## TODO

- implement tools
- constrained playground with data files and documents
- ability to cancel halfway through
- fix md output to normal text
- memory mechanism
- Turn this into a systemd service

Premature optimisation is the root of all evil
- offload voice model to NPU