# Mute Bridge

Demper mikrofonen din i Discord mens du dikterer på Mac (hold **fn**, eller dobbelttrykk **fn**), så de andre slipper å høre diktatet.

Krever Mac med Apple Silicon (M1 eller nyere).

## Installer

Åpne **Terminal** og lim inn:

```
curl -fsSL https://raw.githubusercontent.com/magnusskjoldball-dot/mute-bridge/main/install.sh | bash
```

Deretter, bare første gang:

1. **Systeminnstillinger → Personvern og sikkerhet**: slå på Mute Bridge under *Mikrofon* og *Input Monitoring* (trykk + og velg appen). Velg så *Start på nytt* i menylinje-ikonet.
2. **Discord → Innstillinger → Voice & Video → Input Device**: velg **BlackHole 2ch**.

## Bruk

- **Hold fn**: mutet så lenge du holder.
- **Dobbelttrykk fn**: mutet til du trykker fn igjen (eller Esc).

**Drift:** Som standard er Bridge *automatisk*: den bruker mikrofonen bare mens du er i en Discord-samtale (og er ellers av). Endre under *Drift* i menyen.

Menylinjen viser søyler som følger stemmen din: lilla/blå = sendes, rød = mutet, oransje = låst, grå = av.
Mikrofonen er den Macen bruker som standard. Bytt under *Mikrofon* i menyen.

## Oppdatering

Appen varsler når det finnes en ny versjon. Kjør installasjonslinjen på nytt for å oppdatere.

<details>
<summary>Installere for hånd</summary>

1. Last ned `BlackHole2ch.pkg` fra [denne releasen](../../releases/tag/blackhole-0.7.1) og installer.
2. Last ned `Mute-Bridge.zip` fra [siste release](../../releases/latest), pakk ut og dra **Mute Bridge** til Programmer.
3. Høyreklikk appen og velg **Åpne** første gang.

</details>

<details>
<summary>Om BlackHole</summary>

BlackHole 2ch er laget av [Existential Audio](https://existential.audio/blackhole/) (GPL-3.0, [kilde](https://github.com/ExistentialAudio/BlackHole)). `BlackHole2ch.pkg` i releasen `blackhole-0.7.1` er uendret original.

</details>

Bygge selv: `./build.sh` (krever Xcode Command Line Tools).
