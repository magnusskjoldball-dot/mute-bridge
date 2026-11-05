# Mute Bridge

Demper mikrofonen din i Discord mens du dikterer på Mac (hold **fn**, eller dobbelttrykk **fn**), slik at de andre i samtalen slipper å høre diktatet.

Mikrofonen din sendes via den virtuelle lydenheten **BlackHole 2ch**. Discord bruker BlackHole som mikrofon, mens diktering og andre apper bruker den vanlige mikrofonen. Mens du dikterer sendes det stillhet til BlackHole.

Krever en Mac med Apple Silicon (M1 eller nyere), macOS 12 eller nyere.

## Installere

1. Installer **BlackHole 2ch** fra <https://existential.audio/blackhole/> (velg 2ch). Start Macen på nytt hvis enheten ikke dukker opp.
2. Last ned `Mute-Bridge.zip` fra [siste release](../../releases/latest), pakk ut og dra **Mute Bridge** til Programmer.
3. Første gang: høyreklikk appen og velg **Åpne**, og trykk Åpne igjen (appen er ikke signert av Apple). Kommer det fortsatt en advarsel, kjør i Terminal:
   ```
   xattr -dr com.apple.quarantine "/Applications/Mute Bridge.app"
   ```
4. Systeminnstillinger → Personvern og sikkerhet:
   - **Mikrofon**: slå på for appen.
   - **Input Monitoring**: trykk +, velg appen og slå den på.
   Velg deretter *Start på nytt* i menylinje-ikonet.
5. Discord → Innstillinger → Voice & Video → Input Device = **BlackHole 2ch**.

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
