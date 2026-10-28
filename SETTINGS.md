# Genius Typer settings reference

Every setting is a key in the user defaults of `com.dmemruk.GeniusTyper`, so a script or an AI
agent can set Genius Typer up without clicking through the settings window. Everything here can
also be changed in the app.

## How to change a setting

Quit Genius Typer first (it writes its in-memory values back), change the keys, start it again.

```bash
osascript -e 'tell application id "com.dmemruk.GeniusTyper" to quit'
defaults write com.dmemruk.GeniusTyper yoFix -bool false
open ~/Applications/"Genius Typer.app"
```

Read everything: `defaults read com.dmemruk.GeniusTyper`. Remove a key to go back to the default:
`defaults delete com.dmemruk.GeniusTyper yoFix`.

## Layout (Раскладка)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `paused` | bool | `false` | `true` = "Исправлять текст" off: no auto-fix, no ё (Caps Lock still switches the layout). |
| `capsLockSwitching` | bool | `true` | Caps Lock switches the layout (works even while `paused`). |
| `autoFix` | bool | `true` | Fix words typed in the wrong layout after a space or punctuation. |
| `yoFix` | bool | `true` | "еще" → "ещё". |
| `userExceptions` | array of strings | empty | Words, as typed, that are never fixed. |
| `autoOffApps` | array of bundle IDs | terminals, Xcode, VS Code, JetBrains GoLand, Antigravity | "Не исправлять в": typing is watched, nothing is fixed. |
| `excludedApps` | array of bundle IDs | Bitwarden, 1Password, Passwords, Keychain Access, Yubico | "Не следить в": neither typing nor copies are watched. |
| `wordLog` | bool | `true` | Words log of fixes (`Application Support/GeniusTyper/words/`, 30 days). |
| `fixExceptions` | array of strings | empty | Hashes from undos in versions before 0.3.0 (still honoured). |

```bash
defaults write com.dmemruk.GeniusTyper userExceptions -array len rec смс
defaults write com.dmemruk.GeniusTyper autoOffApps -array-add com.sublimetext.4
```

## Clipboard (Буфер обмена)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `clipboardHistory` | bool | `true` | Keep a clipboard history. |
| `clipboardLimitMB` | int | `100` | Size limit (the app offers 50 / 100 / 200 / 500); at most 1000 entries. |
| `clipboardHotKey` | data (JSON) | ⇧⌘C | `{"keyCode": 8, "modifiers": 1179648}`: a key code and `NSEvent.ModifierFlags` raw value. Easier to change in the app. |

## Dictation (Диктовка)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `dictationEnabled` | bool | `false` | The Диктовка switch: off = no key watched, no microphone, no model. |
| `dictationShortcut` | data (JSON) | right ⌥ | `{"keyCode": 61, "modifiers": 0}`; `modifiers` 0 = a modifier key alone. |
| `engine` | string | `parakeetUltra` | `parakeetUltra`, `parakeetV3` (local), `groq`, `openAI`, `custom`. |
| `baseURL.<engine>` | string | the service's | Address of an OpenAI-compatible API (`baseURL.custom` for "Другой сервис"). |
| `model.<engine>` | string | the service's | Model name, e.g. `model.groq` = `whisper-large-v3-turbo`. |
| `unloadAfterMinutes` | int | `5` | The local model leaves memory after this many idle minutes; `0` = never. |
| `dictationYo` | bool | `true` | ё in dictated text. |
| `dictationSounds` | bool | `true` | Start and done sounds. |
| `escCancels` | bool | `true` | Esc cancels a recording. |
| `levelStyle` | string | `bars` | Microphone level in the pill: `bars`, `wave`, `line`. |
| `levelScales` | data (JSON) | — | Learnt scale of the level bars per microphone name (`floor`, `peak`, in level units of 40 dB per 1.0); written when a dictation ends. Delete it to start over. |
| `mascot` | string | `none` | Animation above the pill: `none`, `wigCat`, `bruce` (the removed `monkey` and `greyCat` read as `none`). |
| `voicesEnabled` | bool | `true` | Telegram voice messages (inside dictation). |
| `voicesShortcut` | data (JSON) | ⌃⌥V | Same format as `clipboardHotKey`. |
| `voicesKeepDays` | int | `7` | Voice message texts are kept this many days (1 / 3 / 7 / 30; 0 = forever, new voice messages of the last 7 days are then transcribed on opening). |

API keys are not in the defaults: they are in the login Keychain, service `com.dmemruk.GeniusTyper`,
account = the engine (`groq`, `openAI`, `custom`).

## Menu bar icon (Основное)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `iconShowsSymbol` | bool | `true` | The "G" icon. |
| `iconLanguageMark` | string | `none` | Current language on the icon: `none`, `text` (RU / EN), `flag`. |

## Statistics window

`statsKind`, `statsPeriod`, `statsShowWeek`, `historyKind`: the last tab and period shown; nothing to set by hand.

## Debugging

| Key | Type | Meaning |
|---|---|---|
| `verboseLog` | bool | Debug lines in `~/Library/Logs/GeniusTyper/geniustyper.log` (restart to apply). |
| `saveDictationAudio` | string | Launch argument `-saveDictationAudio <file.wav>`: each dictation's audio is written there. |
| `voicesRoot` | string | Launch argument `-voicesRoot <folder>`: look for voice messages in a test folder. |
