# Deutsch (de)

Source: the English section of ../metadata.md, in the Sie form of the app's welcome texts. UI terms from App/Resources/Localizable.xcstrings; Screen Recording and Reduce Motion as in German System Settings.

**Name** (27): `Mwoyeo – Vor Ort übersetzen`

**Subtitle** (28): `Ihr Bildschirm, Ihre Sprache`

**Promotional text** (166):
Chats, Spiele, Untertitel, Papers: Mwoyeo löscht das Original und schreibt die Übersetzung an dieselbe Stelle, in gleicher Größe und Farbe. Standardmäßig auf dem Mac.

**Keywords**: `Übersetzer,Bildschirmübersetzer,Live,OCR,Overlay,Spiele,Untertitel,Chat,Japanisch,Koreanisch,Linse`

**Description**:
Fremdsprachiger Text auf Ihrem Bildschirm, direkt an Ort und Stelle übersetzt.

Kein Pop-up, keine Untertitelleiste. Mwoyeo liest den Text unter einer Linse, löscht ihn vom Bildschirm und schreibt die Übersetzung an dieselbe Stelle, in gleicher Größe und Farbe. So wirkt die Seite, als wäre sie von Anfang an in Ihrer Sprache, und die Übersetzung hält Schritt, wenn neue Nachrichten eintreffen oder Sie scrollen.

Eine Linse für
• Chats und Feeds: Neue Nachrichten werden übersetzt, sobald sie eintreffen.
• Spiele und Videountertitel: auch Text auf gemusterten Hintergründen und in bewegten Szenen.
• Fachartikel und Dokumente: Zweispaltige Artikel werden Spalte für Spalte an Ort und Stelle übersetzt; Code und Formeln bleiben unverändert.
• Bilder: Legen Sie eine Bilddatei ab oder fügen Sie sie ein („Bild übersetzen …“), und sie wird genauso übersetzt.

So funktioniert es
• Drücken Sie ⌃⌥L und ziehen Sie ein Rechteck über den Text, den Sie lesen möchten. Klicks gehen durch die Linse hindurch, Sie scrollen und chatten also wie gewohnt.
• Mit ⌃⌥O wechseln Sie zwischen Original und Übersetzung („Original anzeigen“).
• Eine Fensterlinse bewegt sich mit ihrem Fenster; eine Bildschirmlinse bleibt stehen und übersetzt alles, was darunter liegt.
• Das Linsenmenü bietet „Originaltext kopieren“, „Übersetzung kopieren“, „Vorlesen“ und „Linsenbild sichern“.
• Linsen lassen sich mit der Tastatur platzieren, und VoiceOver liest sie vor. Ist „Bewegung reduzieren“ aktiviert, bleibt die Linse ruhig.

Datenschutz
Standardmäßig verwendet Mwoyeo Apple Übersetzung, alles bleibt auf Ihrem Mac, und nichts von Ihrem Bildschirm wird irgendwohin gesendet. Es gibt keine Analysewerkzeuge. Sie können eine Engine auf diesem Mac hinzufügen, etwa Ollama oder LM Studio, oder eine Cloud-Engine mit Ihrem eigenen Schlüssel. Eine Cloud-Engine fragt einmal pro Engine und Host um Erlaubnis, bevor etwas gesendet wird, und es wird nur der Text gesendet, den eine Linse liest, nie ein Bild Ihres Bildschirms. Schlüssel werden ausschließlich im macOS-Schlüsselbund gespeichert.

Voraussetzungen
• macOS 26 oder neuer, Apple Silicon (M1 oder neuer)
• Berechtigung „Bildschirmaufnahme“ (zum Lesen des Texts unter einer Linse; es wird nichts aufgezeichnet oder gespeichert)
• Mit einem Sprachpaket erscheint die Übersetzung fast sofort und funktioniert auch offline.
