# Mute Bridge

Demper mikrofonen din i Discord mens du dikterer på Mac (hold **fn**, eller dobbelttrykk **fn**), slik at de andre i samtalen slipper å høre diktatet.

Mikrofonen din sendes via den virtuelle lydenheten **BlackHole 2ch**. Discord bruker BlackHole som mikrofon, mens diktering og andre apper bruker den vanlige mikrofonen. Mens du dikterer sendes det stillhet til BlackHole.

Krever en Mac med Apple Silicon (M1 eller nyere), macOS 12 eller nyere.

## Installere (enklest)

Åpne **Terminal** (Cmd+mellomrom, skriv «Terminal») og lim inn denne linjen:

```
curl -fsSL https://raw.githubusercontent.com/magnusskjoldball-dot/mute-bridge/main/install.sh | bash
```

Skriptet installerer BlackHole 2ch (hvis den mangler, Macen ber om passordet ditt), laster ned og installerer Mute Bridge i Programmer, og starter den. Du slipper unzip, høyreklikk og advarsler.

Gjør deretter to ting (bare første gang):

1. Systeminnstillinger → Personvern og sikkerhet:
   - **Mikrofon**: slå på for Mute Bridge.
   - **Input Monitoring**: trykk +, velg Mute Bridge fra Programmer og slå den på.
   Klikk så på ikonet i menylinjen og velg *Start på nytt*.
2. Discord → Innstillinger → Voice & Video → Input Device = **BlackHole 2ch**.

### Installere for hånd

1. Installer BlackHole 2ch: last ned `BlackHole2ch.pkg` fra [denne releasen](../../releases/tag/blackhole-0.7.1) (original fra Existential Audio) og dobbeltklikk.
2. Last ned `Mute-Bridge.zip` fra [siste release](../../releases/latest), pakk ut og dra **Mute Bridge** til Programmer.
3. Høyreklikk appen og velg **Åpne** første gang (appen er ikke signert av Apple), eller kjør `xattr -dr com.apple.quarantine "/Applications/Mute Bridge.app"`.
4. Gjør steg 1 og 2 ovenfor.

Appen gir deg et tips hvis du dikterer i en Discord-samtale og Discord ikke bruker BlackHole (macOS 14.2 eller nyere).

## Bruk

| Handling | Resultat |
|---|---|
| Hold **fn** | Mutet så lenge du holder tasten |
| Dobbelttrykk **fn** | Mutet til du trykker fn igjen |
| **Esc** eller *Lås opp mikrofon* i menyen | Åpner lyden igjen (låst mute åpnes også av seg selv etter 3 minutter) |

Menylinjen viser fem små søyler som følger stemmen din: lilla/blå = sendes til Discord, rød = mutet, oransje (blinker) = låst mute, grå = av.

**Mikrofon:** Som standard brukes den mikrofonen Macen bruker (innebygd, headset eller ekstern). Velg en annen under *Mikrofon* i menyen. Kobler du til eller fra en mikrofon, bytter appen automatisk.

## Oppdateringer

Appen sjekker GitHub ved oppstart og deretter hver sjette time. Er det en nyere release, får du et varsel og et valg i menyen. Du laster ned og erstatter appen selv.

## Bygge selv

```
./build.sh
```

Krever Xcode Command Line Tools.

## BlackHole

BlackHole 2ch er laget av [Existential Audio](https://existential.audio/blackhole/) og lisensiert under GPL-3.0, kildekode: <https://github.com/ExistentialAudio/BlackHole>. `BlackHole2ch.pkg` i denne repoets release `blackhole-0.7.1` er uendret original, signert og notarisert av Existential Audio.
