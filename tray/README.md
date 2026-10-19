# Claude Usage voor Windows en Ubuntu

Eén app in Python en Qt (PySide6) met een tray-icoon en een paneel.
Zie de [hoofd-README](../README.md) voor wat de app doet en hoe je hem installeert.

## Draaien en testen

```bash
python -m venv .venv && . .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python main.py
python -m unittest discover tests
```

Iconen opnieuw maken: `python tools/make_icons.py`. Dit schrijft `assets/icon.png` en
`assets/icon.ico`.

## Bestanden

- `claude_usage/data.py`: leest de login uit `.credentials.json`, haalt de limieten op en
  telt de tokens. Bevat ook de opmaak.
- `claude_usage/app.py`: het tray-icoon, het paneel en de besturing. Het paneel opent boven het
  icoon als de taakbalk onderaan staat (Windows) en eronder als de balk bovenaan staat (Ubuntu).
- `claude_usage/icons.py`: tekent het app-icoon en het tray-icoon met het percentage erin.
- `claude_usage/autostart.py`: start bij inloggen. Op Windows via het register (`HKCU\…\Run`),
  op Ubuntu via `~/.config/autostart`.
- `main.py`: het startpunt. Onder Wayland draait de app via XWayland, zodat het paneel bij het
  icoon kan verschijnen.

De builds komen uit `../.github/workflows/build.yml` (PyInstaller, `--onefile`).
