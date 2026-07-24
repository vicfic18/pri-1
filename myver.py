import evdev
from evdev import InputDevice, categorize, ecodes

keyboard_path = '/dev/input/event4'
dev = InputDevice(keyboard_path)

pressed_keys = set()
target_combination = {'KEY_LEFTSHIFT', 'KEY_LEFTMETA', 'KEY_F23'}
combination_active = False

print(f"Listening on {dev.name} ({dev.path})...")

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

        # Check if combination is newly met
        if not combination_active and target_combination.issubset(pressed_keys):
            combination_active = True
            print(f"Pressed: {' + '.join(target_combination)}")

        # Check if combination is broken (any required key released)
        elif combination_active and not target_combination.issubset(pressed_keys):
            combination_active = False
            print(f"Released: {' + '.join(target_combination)}")