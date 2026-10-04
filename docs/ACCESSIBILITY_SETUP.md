# Enabling the Maxima Accessibility Service

The volume-button long-press mute and global-action dispatch run through
`MaximaAccessibilityService`. Android requires the user to enable an
accessibility service manually — apps cannot self-grant this permission.

## Steps

1. Install and launch the app; complete the initial permission prompt.
2. From the app, call the platform method `openAccessibilitySettings`,
   or open it manually:
   **Settings → Accessibility → Installed services** (Samsung:
   **Settings → Accessibility → Interaction and dexterity → Installed
   services**).
3. Select **Maxima Accessibility Service** and toggle it **On**.
4. Accept the system warning dialog — the service only observes key
   events (`KEYCODE_VOLUME_UP/DOWN`) and dispatches global actions; it
   does not read screen content.

## Verifying from the app

The method channel exposes a status check:

```dart
const channel = MethodChannel('aura.straton.maxima/accessibility');
final enabled =
    await channel.invokeMethod<bool>('isAccessibilityServiceEnabled');
final opened =
    await channel.invokeMethod<bool>('openAccessibilitySettings');
```

## Behavior after enabling

| Input                         | Result                                   |
|-------------------------------|------------------------------------------|
| Volume key short press        | Normal system volume adjustment          |
| Volume key long press (>600ms)| Toggles compliant microphone mute        |
| `executeGlobalAction` channel | Dispatches `GLOBAL_ACTION_*` to the OS   |

## Notes

- Mic mute uses `AudioManager.isMicrophoneMute`; the Android privacy
  indicator remains honest while the stream is active.
- If the service is disabled by the system (e.g. after an update), the
  app reports `isAccessibilityServiceEnabled == false` and hardware
  controls are inert until re-enabled.
