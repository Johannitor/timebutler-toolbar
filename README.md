# Timebutler Toolbar

Native macOS-Menüleisten-App (Swift 6, SwiftUI) für die Timebutler-Stempeluhr. Sie nutzt die Timebutler API v2 mit einem persönlichen Zugriffstoken.

## Funktionen

- Einstempeln, Pause starten/beenden, Ausstempeln und Schicht verwerfen direkt aus der Menüleiste
- Menüleisten-Anzeige der Netto-Arbeitszeit (`H:MM`), auch bei geschlossenem Fenster
- Detailfenster mit Beginn, Brutto, Pausen, laufender Pause und Tagessumme („Heute“) inkl. Soll/Rest/Überstunden
- Rückfrage vor Ausstempeln und Abbrechen; Pausenregelung (Korrektur übernehmen / unverändert speichern) wird direkt im Fenster abgefragt
- Pausenerinnerung nach ArbZG: 15 Minuten vor 6 h bzw. 9 h Arbeitszeit, wenn noch nicht genug Pause (30 bzw. 45 Min.) erfasst ist
- Mitteilung bei erreichter Sollzeit und Warnung 15 Minuten vor 10 h Tagesarbeitszeit (ArbZG-Höchstgrenze), jeweils einzeln abschaltbar
- Optionales automatisches Pausenende: Pause mit 30, 45 oder 60 Minuten starten, sie endet dann von selbst und meldet sich per Mitteilung (Einstellung, standardmäßig aus)
- Start bei Anmeldung (optional)
- Token liegt im macOS-Schlüsselbund

## Voraussetzungen

- macOS 15 oder neuer (Apple Silicon)
- Xcode (aktuell) und [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Ein Apple-Konto als Personal Team in Xcode (Team-ID ist in `project.yml` hinterlegt)

## Installation

```sh
brew install xcodegen
scripts/install.sh
```

Das Skript erzeugt das Xcode-Projekt, baut die Release-Version, kopiert `TimebutlerToolbar.app` nach `~/Applications` und startet sie. „Bei Anmeldung starten“ funktioniert zuverlässig nur, wenn die App in `~/Applications` oder `/Applications` liegt.

## Token einrichten

1. In Timebutler ein persönliches Token erstellen: <https://app.timebutler.com/do?ha=personaltoken&ac=1> (oder über „Token in Timebutler erstellen“ in der App).
2. Beim ersten Start öffnet sich das Einstellungsfenster. Token (`tb_…`) einfügen und auf „Prüfen & speichern“ klicken.
3. Das Token wird gegen die API geprüft und nur bei Erfolg im Schlüsselbund gespeichert.

## Entwicklung

```sh
xcodegen generate
xcodebuild -project TimebutlerToolbar.xcodeproj -scheme TimebutlerToolbar \
  -destination 'platform=macOS' -allowProvisioningUpdates build test
```

Die Tests (Swift Testing) verwenden ausschließlich Mocks: Es gibt keine Zugriffe auf die echte API oder den echten Schlüsselbund.

Architektur: `API/` (Client, DTOs, Fehler), `Model/` (`ShiftSnapshot` für die Zeitberechnung, `ShiftStore` als App-Zustand), `Services/` (Pausenerinnerung, Autostart), `UI/` (dünne SwiftUI-Views).

## Bekannte Einschränkungen

- Die API liefert keine Liste einzelner Pausen; angezeigt werden nur Summen und die aktuelle Pause.
- Projekt und Kategorie werden beim Ausstempeln nicht unterstützt (es wird ohne Angaben gestempelt).
- „Heute“ basiert auf der Arbeitszeit-Zusammenfassung (nur gespeicherte Einträge) plus der laufenden Schicht.
- Das automatische Pausenende funktioniert nur, solange die App läuft; schläft der Mac über das Ende hinaus, wird die Pause beim Aufwachen beendet (die API kann nicht rückdatieren).
- Aktionen, die laut Timebutler nur am Terminal erlaubt sind, sind deaktiviert.
