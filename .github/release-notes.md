**Install:** download `GeniusTyper-*.dmg`, open it and drag Genius Typer to Applications. It is not
notarized (no Apple Developer account), so macOS blocks the first launch: open it once, then
System Settings → Privacy & Security → "Open Anyway". Or in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Genius Typer.app"
```

macOS 15+, Apple Silicon (Intel works, local dictation is slower). Genius Typer needs Input
Monitoring and Accessibility, and the microphone once dictation is on (Settings → Основное lists
them). Updates are signed with the same certificate, so these permissions are kept. Once installed,
Genius Typer offers newer versions itself ("Доступна версия" at the top of the menu bar panel:
Обновить, Позже or Пропустить; Settings → Основное → Обновления turns the checks or automatic
installs on and off). Dictation is off on a fresh install; its local model (~630 MB) is downloaded
when you turn it on.

**Установка:** скачайте `GeniusTyper-*.dmg`, откройте и перетащите Genius Typer в «Программы».
Приложение не нотаризовано, поэтому при первом запуске macOS его заблокирует: откройте его один
раз, затем «Системные настройки → Конфиденциальность и безопасность → Всё равно открыть» (или
команда выше). Нужны «Мониторинг ввода», «Универсальный доступ» и, для диктовки, микрофон.
Дальше Genius Typer сам предлагает новые версии: «Обновить», «Позже» или «Пропустить»; в
«Основное → Обновления» можно выключить проверку или включить автоматическую установку.
