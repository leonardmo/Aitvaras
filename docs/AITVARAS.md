# Warum „Aitvaras"?: Namensforschung (2026-07-13)

> Ergebnis: Der lokale KI-Assistent heißt **Aitvaras**, nach dem litauischen
> Hausdrachen und Schutzgeist. Der Name verbindet die Rolle des Assistenten,
> den Drachen-Avatar und robuste Wake-Word-Eigenschaften.

## Bedeutung und Identität

In der litauischen Mythologie ist ein Aitvaras ein häuslicher Geist, der häufig
als kleiner Drache oder feuriges Wesen erscheint. Er lebt nahe am Haus, schützt
es und trägt seinem Menschen Dinge zu. Diese Bildsprache passt zu einem lokalen
Assistenten, der im Hintergrund auf dem eigenen Mac arbeitet, Informationen
zusammenträgt und seinem Nutzer hilft, ohne Daten an einen Cloud-Dienst
abzugeben.

Der Name ist keine bloße Produktbezeichnung. App, Repository, Projekt, Module,
Speicherorte, technische Identität und Figur heißen einheitlich Aitvaras.

## Phonetische Eignung

Ein gutes Wake Word sollte sich klar von gewöhnlicher Sprache abheben und auch
bei Raumhall, Nebengeräuschen und unterschiedlichen Mikrofonabständen erkennbar
bleiben. Aitvaras bietet dafür mehrere günstige Merkmale:

- drei bis vier gut trennbare Silben, je nach Aussprache;
- einen markanten Diphthong am Anfang;
- den harten Plosivlaut /t/ als deutliche zeitliche Landmarke;
- abwechslungsreiche Vokal- und Konsonantenfolgen;
- geringe Verwechslungsgefahr mit häufigen deutschen und englischen Wörtern.

Für ein späteres Custom-Wake-Word-Modell sollten deutsch- und englischsprachige
Aussprachen, verschiedene Distanzen, reale Raumakustik und harte Negativbeispiele
aufgenommen werden. Das Modell muss lokal laufen und darf keine Audiodaten
speichern oder übertragen.

## Visuelle Semiotik

Der Avatar übersetzt die mythologische Idee in eine freundliche, eigenständige
Figur: ein kompakter Hausdrache mit charcoal-navy Körper, warmen Bauchplatten,
feurig rotem Kamm, goldenen Hörnern und Krallen sowie einer glühenden
Schwanzflamme. Die Flamme und weitere Akzente reagieren auf Stimme und Zustand,
ohne die Figur wie ein technisches Statusdisplay wirken zu lassen.

## Implementierungsentscheidung

Die vollständige Namensidentität lautet **Aitvaras**:

- App und ausführbares Produkt: `Aitvaras.app` / `Aitvaras`;
- Xcode-Projekt und Scheme: `Aitvaras.xcodeproj` / `Aitvaras`;
- SwiftPM-Paket und Module: `AitvarasKit`, `AitvarasCore` usw.;
- Bundle Identifier: `app.aitvaras.Aitvaras`;
- Zustandsverzeichnis: `~/Library/Application Support/Aitvaras/`;
- Umgebungsvariablen und interne Präfixe: `AITVARAS_*` / `aitvaras`;
- Kalender, Erinnerungslisten und Besitzmarkierungen: `Aitvaras` / `aitvaras://`.

Damit stimmen Nutzeroberfläche, Laufzeitidentität, Quellcode und Repository
überein.
