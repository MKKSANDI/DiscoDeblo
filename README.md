## Support

<p align="center">
  <a href="https://buymeacoffee.com/thebigtk">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" height="50" width="210" alt="Buy Me A Coffee" />
  </a>
</p>

# Discord Debloat

DiscoDeblo is a Windows cleanup tool for Discord that focuses on safe cache/config cleanup to optimize discord and make it feel faster and be faster

## Project files

- `app.py`: PyQt5 desktop interface
- `debloat_headless.ps1`: cleanup engine used by the UI
- `logo.png` / `logo.ico`: app assets
- `requirements.txt`: Python dependencies
- `releases/`: prebuilt executable output

## Safety model

- does not remove updater/runtime-critical files
- does not remove Discord login/session storage by default
- blocks destructive mod-related actions behind explicit user confirmation
- `LEAN MODS` mode is reversible via restore path

## Run from source

1. Install Python dependencies:

```powershell
python -m pip install -r requirements.txt
```

2. Run the app (elevated/admin recommended):

```powershell
python app.py
```

## Build executable from source (manual command)

```powershell
python -m pip install --upgrade pyinstaller
python -m PyInstaller --noconfirm --clean --onefile --windowed --name "DiscoDeblo" --icon "logo.ico" --add-data "debloat_headless.ps1;." --add-data "logo.png;." app.py
```



## Notes

- app expects `debloat_headless.ps1` and `logo.png` to be bundled for frozen builds
- full operation logs are shown in the UI during execution
