# Claude Usage voor macOS

Een menubalk-app in Swift (AppKit en SwiftUI) zonder externe afhankelijkheden.
Zie de [hoofd-README](../README.md) voor wat de app doet en hoe je hem installeert.

## Bouwen

Je hebt Xcode of de Command Line Tools nodig.

```bash
./build.sh            # bouwen, installeren in ~/Applications en starten
./build.sh --login    # idem, en automatisch starten bij inloggen
./build.sh --unlogin  # automatisch starten weer uitzetten
./build.sh --package  # alleen bouwen en inpakken als build/ClaudeUsage-macos.zip
```

De build is universeel (arm64 en x86_64) en ad-hoc ondertekend.

## Bestanden

- `main.swift`: de hele app. Bevat het ophalen van de limieten (via `/usr/bin/security` uit de
  Keychain), het tellen van de tokens, het paneel en het automatisch starten (LaunchAgent).
- `make_icon.swift`: tekent het app-icoon. `build.sh` maakt `AppIcon.icns` opnieuw aan als dit
  script nieuwer is.
