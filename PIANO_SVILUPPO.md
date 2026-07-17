# Piano di sviluppo — App SIP VoIP per iOS (uso domestico)

Client SIP nativo iOS per sostituire Linphone sull'interno `101`, con obiettivo di ricezione affidabile delle chiamate anche ad app sospesa/terminata, invio DTMF, e la miglior integrazione possibile con l'ecosistema nativo iOS (CallKit, Contatti, Siri).

Contesto infrastrutturale di riferimento: vedi [`.config.local/CONFIGURAZIONE.md`](.config.local/CONFIGURAZIONE.md) (Asterisk 20.8.1 su NanoPi R6S/FriendlyWRT, trunk Vodafone Business, interni PJSIP 100/101, WireGuard per accesso remoto).

## Decisioni architetturali

| Decisione | Scelta | Motivazione |
|---|---|---|
| Motore SIP/RTP | **Linphone SDK (liblinphone)**, integrato via Swift Package Manager | Esempi ufficiali CallKit+PushKit già pronti e mantenuti, coerenza con l'uso attuale di Linphone come client, evita di scrivere uno stack SIP/RTP da zero |
| Push relay (avviso APNs alla chiamata in arrivo) | Servizio containerizzato **Docker** sullo stesso NanoPi R6S, sviluppato in repo dedicato [`SIP-Phone-PushRelay`](https://github.com/manuzzi/SIP-Phone-PushRelay) | Docker è già installato sul router; nessun host aggiuntivo da gestire, immagine versionabile/aggiornabile. Repo separato: runtime/toolchain diversi (Go/Docker vs Swift/Xcode), secrets diversi da gestire (AMI, APNs), ciclo di vita indipendente dalle release dell'app |
| Interno di sviluppo/test | **Riuso diretto dell'interno 101** | Inizialmente `max_contacts=2` per coesistere con Linphone durante i test; portato a **`max_contacts=1`** durante M2 dopo aver scoperto che ogni riavvio dell'app lascia un contatto SIP fantasma (nuova porta UDP ad ogni lancio), che il vecchio valore lasciava accumulare causando fork verso contatti morti |
| Videochiamate | **Fuori scope** (solo audio) | Coerente con l'uso attuale (telefonia fissa + interni); Linphone SDK supporta comunque video se servisse in futuro |
| Cifratura SIP/RTP | **Invariata** (UDP in chiaro, no TLS/SRTP) | Il traffico remoto è già protetto dal tunnel WireGuard; nessuna modifica lato Asterisk per restare nello scope minimo |
| Distribuzione | App personale, architettura pulita (no credenziali hardcoded), eventuale apertura futura da valutare | Vedi nota licenza SDK sotto |

**Nota licenza SDK (da rivalutare prima di M6):** Linphone SDK è distribuito in dual-license GPLv3 / commerciale. Uso personale (installazione diretta via Xcode/TestFlight privato) non pone alcun vincolo. Una eventuale pubblicazione pubblica su App Store richiederebbe però rilasciare il codice sorgente dell'app sotto GPLv3, oppure acquistare una licenza commerciale da Belledonne Communications.

## Architettura

```
iPhone (app SIP)                    NanoPi R6S / FriendlyWRT
┌─────────────────────┐            ┌──────────────────────────────┐
│ Linphone SDK          │  SIP/RTP  │ Asterisk 20.8.1                │
│ (liblinphone)         │◄──UDP────►│  interno 101 (riusato)         │
│ CallKit + PushKit      │  :5060    │  ARI + HTTP (nuovo, localhost)  │
│ Intents Extension      │           │  dialplan: Stasis(homesip-      │
└──────────▲────────────┘           │  wakeup) come fallback dopo un  │
     VoIP  │      /device-ready     │  primo Dial() diretto fallito   │
     Push  │      (dopo REGISTER)   └──────────┬───────────────────────┘
    (APNs) │  ┌─────────────────────────────────┘ StasisStart + ring/continue
           └──┤ Push relay (Docker, Go) — client ARI (WebSocket eventi + REST)
              └─────────────────────────────────────────────────────────────
```

Il relay non si limita più a osservare (come un design iniziale basato su AMI):
tiene la chiamata in pausa finché l'app non conferma di essersi ri-registrata,
invece di indovinare un tempo di attesa fisso — vedi dettaglio più sotto.

## Milestone

### M0 — Setup e spike tecnico
- Apple Developer Program attivato (richiesto per l'entitlement VoIP Push)
- Progetto Xcode con Linphone SDK integrato (SPM), App ID con capability Push Notifications + Background Modes (audio, voip)
- Registrazione SIP hardcoded su interno 101, chiamata di prova con audio bidirezionale su WiFi casalingo
- **Validazione:** audio chiaro in entrambe le direzioni, codec alaw/ulaw negoziato correttamente nei log Asterisk

### M1 — MVP di chiamata in foreground
- UI minima (schermata in-chiamata: mute, speaker, riaggancio, tastierino)
- Integrazione CallKit per l'interfaccia di sistema
- Chiamate uscenti verso interno 100 e verso la rete Vodafone esterna
- Chiamate entranti con app aperta/attiva in background
- **Validazione:** chiamata verso un numero esterno reale e ricezione di una chiamata dall'esterno con app aperta, qualità comparabile a Linphone

### M2 — Affidabilità in background: PushKit + push relay ✅ completata
- Push relay containerizzato (Go, immagine minimale, `network_mode: host`) collegato ad Asterisk via **ARI** (non AMI: vedi dettaglio più sotto per il perché del cambio)
- App: gestione PushKit → `reportNewIncomingCall` immediato → correlazione con il vero INVITE quando arriva (gestisce anche il caso in cui l'utente risponde prima che l'INVITE sia arrivato)
- Dialplan con fallback su `Stasis(homesip-wakeup)` quando il primo tentativo diretto su 101 fallisce, invece di un'attesa a tempo fisso
- Endpoint locale `/device-ready` (oltre a `/register-token`), protetto da bearer secret, accessibile solo da LAN/WireGuard
- **Validazione:** chiamata ricevuta con successo in foreground, background e **app completamente terminata**, sia da chiamata interna (Mac→101) sia da chiamata esterna reale (Vodafone); audio bidirezionale confermato

**Percorso reale (per riferimento futuro):** il primo design (osservare `DialBegin` via AMI + attesa fissa `Wait(4)` nel dialplan prima di ritentare) si è rivelato inaffidabile — bug applicativi (doppio accept CallKit+UI, risposta prima dell'INVITE reale, push ridondante ad app già in foreground) mascheravano inizialmente il problema di fondo: Asterisk non aspetta che l'app si risvegli, fallisce subito se il contatto SIP non è ancora registrato nell'istante esatto del `Dial()`. Risolti i bug applicativi, restava il problema di timing — la soluzione strutturale (ispirata a come Flexisip, il push gateway ufficiale di Linphone, risolve lo stesso problema) è passare da un'attesa indovinata a un'attesa **basata su segnale reale**, usando ARI/Stasis per mettere in pausa la chiamata finché l'app non conferma di essere pronta.

### Fix — Registrazione SIP su cellulare+VPN (anticipato da M5) ✅ risolto
- **Sintomo:** con l'iPhone su rete cellulare + WireGuard, la REGISTER raggiungeva sempre Asterisk e Asterisk rispondeva sempre correttamente con `401 Unauthorized`, ma il telefono non la elaborava mai: restava bloccato a ritrasmettere la REGISTER originale non autenticata (visibile anche a occhio come "Refreshing"/"Failed — io error"). Su WiFi locale (nessuna VPN) tutto funzionava.
- **Ipotesi scartate, in ordine:** cambio percorso di rete non gestito da Linphone (fix con `NWPathMonitor` + ri-registrazione forzata: non risolutivo, il problema si presentava anche a Core appena avviato senza alcun cambio di percorso rilevato); interferenza del debounce sul path monitor con la REGISTER iniziale (escluso: il problema persisteva anche senza che il path monitor rilevasse alcun cambiamento); frammentazione MTU della risposta 401 nel tunnel WireGuard (escluso: persisteva anche con MTU abbassato a 1280, ben sotto qualunque soglia realistica per quel pacchetto).
- **Diagnosi risolutiva:** `tcpdump` mirato sul router (interfaccia `wg0` e WAN) più `pjsip set logger on` su Asterisk hanno confermato che il 401 viene sempre inviato, correttamente indirizzato, e che il tunnel WireGuard lo consegna fisicamente al telefono (contatori di trasferimento in aumento). Aumentando la verbosità di logging di liblinphone lato client (`LoggingService.Instance.logLevelMask`) si è visto che il socket UDP "connesso" di belle-sip non riceve mai nulla in risposta — solo righe di invio, mai di ricezione. Causa isolata: interazione nota e poco affidabile tra socket UDP connessi e VPN basate su `NEPacketTunnelProvider` (come l'app WireGuard su iOS) — il pacchetto arriva all'interfaccia di tunnel ma non viene consegnato al socket applicativo.
- **Fix:** trasporto SIP passato da UDP a **TCP**, sia sull'account Linphone (`SIPManager.registerAccount()`) sia su Asterisk (nuovo `[transport-tcp]` in `pjsip.conf`, endpoint 101 configurato con `transport=transport-tcp`). TCP non soffre di questa classe di problema.
- **Validazione:** registrazione stabile su cellulare+VPN, contatto confermato "Avail" via `pjsip show endpoint 101`, chiamata reale in/out con audio funzionante confermata dall'utente.

### M3 — DTMF e funzionalità in chiamata ✅ completata
- Tastierino DTMF in-call (RFC4733, già configurato lato Asterisk con `dtmf_mode=rfc4733`) — già presente in `CallView.swift`
- Supporto DTMF anche dalla UI di sistema CallKit (`CXPlayDTMFCallAction`) — già presente in `CallManager.swift`; corretto un bug per cui veniva inviata solo la prima cifra quando l'azione ne conteneva più di una
- Test contro un risponditore automatico reale
- **Validazione:** cifre riconosciute correttamente dal risponditore, nessun problema di timing o invii doppi — confermato dall'utente

### M3.5 — Configurazione utente e revisione UI
- Rimosso l'hardcoding dei parametri SIP (`SIPCredentials.swift`): ora configurabili in Impostazioni di sistema > HomeSIP (`Settings.bundle`/`Root.plist`), lette a runtime da `SIPSettings` (wrapper su `UserDefaults`)
- Se l'account non è ancora configurato l'app mostra una schermata dedicata con link diretto a Impostazioni, invece di tentare una registrazione con credenziali vuote; al ritorno in foreground (`scenePhase`) ritenta automaticamente la registrazione
- Dialer nella home ridisegnato in stile Telefono di iOS: tastierino numerico con lettere (`DialerView.swift`), cancellazione, pulsante di chiamata verde — layout condiviso con il tastierino DTMF in chiamata (`PhoneKeypadLayout.swift`)
- Interfaccia durante la chiamata ridisegnata in stile Telefono di iOS: sfondo scuro, pulsanti circolari traslucidi, timer di durata chiamata, tastierino DTMF a schermo intero con log delle cifre inviate (`CallView.swift`)
- **Validazione:** schermata "non configurato" e dialer verificati su simulatore; interfaccia in chiamata da validare in una chiamata reale su dispositivo fisico

### M4 — Integrazione con Contatti/Siri ✅ completata
- Intents Extension `HomeSIPIntents` (target `app-extension` separato) che implementa `INStartCallIntentHandling`: risolve contatto/capability e risponde sempre `.continueInApp`, perché l'estensione gira in un processo sandboxato senza accesso al Core Linphone — la chiamata vera parte dall'app principale (`HomeSIPApp.onContinueUserActivity`)
- Dopo ogni chiamata connessa (in o out), `CallDonationManager` dona una `INInteraction` con `INStartCallIntent`: è questo storico di donazioni, non una configurazione statica, che nel tempo fa comparire HomeSIP come opzione di chiamata su un contatto e abilita "Chiama [nome] con HomeSIP" via Siri
- Chiamate visibili nei Recenti di sistema: già garantito dall'uso di CallKit fin da M1 (`CXProvider.reportNewIncomingCall`/`reportOutgoingCall`), nessun lavoro aggiuntivo necessario
- **Valutazione "app di chiamata predefinita" (iOS 18+):** non implementata. Diventare l'app predefinita intercetterebbe *tutti* i link `tel:` di sistema (Safari, Messaggi, ecc.), anche numeri che il trunk Vodafone non può raggiungere o casi limite come le emergenze — rischio sproporzionato rispetto al beneficio per un uso home/personale. Da riconsiderare solo se in futuro HomeSIP diventasse il modo primario di effettuare chiamate.
- *Nota: non è possibile intercettare il tastierino dell'app Telefono nativa per numeri PSTN generici — questa è la forma di integrazione più vicina realizzabile su iOS.*
- **Percorso reale:** l'errore di build `Entitlement com.apple.developer.siri not found` ha richiesto due passaggi manuali non ovvi: (1) aggiungere la capability Siri da Xcode e **tentare davvero una build** (aggiungerla dal pannello Signing & Capabilities senza compilare non basta, Xcode negozia con il portale solo al build) e (2) creare manualmente su developer.apple.com l'App ID `work.manuzzi.homesip.intents` per il target dell'estensione, perché la registrazione automatica di un App ID nuovo con una capability non ancora abilitata sull'account non riesce da CLI (`-allowProvisioningUpdates`) né dal primo tentativo in Xcode.
- **Validazione:** dall'app Contatti tocchi l'icona dell'app su un contatto e parte la chiamata SIP; la chiamata compare nei Recenti di sistema; comando Siri "Chiama [nome] con HomeSIP" funzionante dopo alcune chiamate donate

### M5 — Robustezza e uso quotidiano
- Gestione cambio rete (WiFi casa ↔ cellulare+VPN ↔ perdita connessione) con ri-registrazione automatica — *registrazione su cellulare+VPN già validata (vedi fix trasporto TCP dopo M2); resta da validare il comportamento in transizione live tra le reti*
- Notifiche locali se il server non è raggiungibile
- Test sul campo di 1-2 settimane come sostituto quotidiano di Linphone, con log delle chiamate perse
- **Validazione:** zero chiamate perse nel periodo di test, comportamento stabile su riavvii di telefono/app update

### M6 — Opzionale, solo se si decide di procedere verso l'App Store
- Rimozione di eventuali residui hardcoded
- Risoluzione della questione di licenza SDK (GPL vs licenza commerciale Belledonne)
- Revisione requisiti App Review per app CallKit/VoIP, naming/branding non legato a Vodafone o dati personali
- Distribuzione TestFlight pubblica o submission

## Dettaglio push relay (M2)

Repo dedicato: [`SIP-Phone-PushRelay`](https://github.com/manuzzi/SIP-Phone-PushRelay).

### Container e networking
`network_mode: host` invece del bridge Docker di default: su OpenWrt il bridge interagisce in modo imprevedibile con `fw4`/`nftables`, e il servizio non deve esporre porte verso l'esterno — solo connessioni in uscita verso Asterisk (localhost) e APNs.

### Dialplan: fallback su Stasis
Il primo tentativo su 101 resta un `Dial()` diretto e veloce (copre il caso comune: app già registrata, sospesa ma non terminata). Solo se quel tentativo fallisce, il canale entra nell'app Stasis `homesip-wakeup`, che il relay controlla via ARI:

```
exten => 101,1,Dial(PJSIP/101,8)
 same => n,GotoIf($["${DIALSTATUS}" = "ANSWER"]?done)
 same => n,Stasis(homesip-wakeup,101)
 same => n,Dial(PJSIP/101,15)
 same => n(done),Hangup()
```

Stesso pattern in `[from-vodafone]` per le chiamate esterne (che forkano su `PJSIP/100&PJSIP/101`): il fallback su Stasis scatta solo se nessuno dei due ha risposto, senza toccare l'esperienza su Mac (100).

### Configurazione ARI/HTTP (`/etc/asterisk/http.conf` + `ari.conf`)
Richiede pacchetti opkg aggiuntivi non installati di default: `asterisk-res-ari`, `-applications`, `-channels`, `-events`, `asterisk-res-stasis`, `asterisk-app-stasis`, `asterisk-res-stasis-answer`.

```ini
; http.conf
[general]
enabled = yes
bindaddr = 127.0.0.1
bindport = 8089   ; 8080 già occupata da uhttpd/LuCI, 8088 dal relay stesso

; ari.conf
[general]
enabled = yes

[homesip]
type = user
read_only = no
password = <secret-random-forte>
```

### Flusso: StasisStart → push → attesa → continue
1. Il canale entra in Stasis → il relay riceve `StasisStart` via WebSocket (`/ari/events`)
2. `POST /channels/{id}/ring` — il chiamante sente lo squillo invece del silenzio durante l'attesa
3. Invio VoIP Push APNs con i dati del chiamante (dall'evento stesso, non serve più interrogare Asterisk separatamente)
4. Attesa (con timeout di 20s) di un segnale `/device-ready` dall'app
5. `POST /channels/{id}/continue` — la chiamata torna al dialplan, che a quel punto trova il contatto (si spera) già registrato

Nessun dedup necessario: a differenza del vecchio design basato su AMI (dove un `Dial()` che forka su più contatti genera più eventi `DialBegin` per la stessa chiamata), qui `Stasis()` viene invocato una sola volta per chiamata, solo sul ramo 101 specifico.

### VoIP Push (APNs)
- Auth key `.p8` token-based (JWT ES256, claims `iss=<Team ID>`, `kid=<Key ID>`, rigenerato ogni ~50 min)
- `POST https://api.push.apple.com/3/device/<token>` (sandbox per build di sviluppo firmate "Development", come quelle lanciate da Xcode)
- Header: `apns-topic: <bundle-id>.voip`, `apns-push-type: voip`, `apns-priority: 10`, `apns-expiration` breve (~30s)

### Endpoint HTTP del relay
```
POST /register-token      { "deviceToken": "..." }   — nuovo token PushKit
POST /device-ready                                    — l'app si è ri-registrata
GET  /healthz                                         — stato connessione ARI
```
Tutti (tranne `/healthz`) protetti da bearer secret condiviso. Device token persistito su volume Docker montato, non nell'immagine.

### Deployment
Dockerfile multi-stage (build Go arm64 → immagine finale `distroless/static`), `docker-compose.yml` con `restart: unless-stopped`, log con `max-size`/`max-file` per non riempire la flash del router. Verificare `/etc/init.d/dockerd enable` per il riavvio automatico dopo reboot del router. Unica dipendenza esterna del modulo Go: `gorilla/websocket` (client eventi ARI) — non vale la pena scriverne uno a mano solo per evitare una dipendenza.

### Resilienza
- Riconnessione ARI (WebSocket) con backoff esponenziale
- Gestione errori APNs (`410 Unregistered` → invalida token salvato; errori di firma/topic → log di alta severità)
- Endpoint `/healthz` che riflette lo stato della connessione ARI
- Se `/device-ready` non arriva mai (app non si ri-registra), il timeout di 20s in Stasis fa comunque procedere il `continue`, evitando che la chiamata resti bloccata all'infinito

### Test specifici (tutti superati)
1. Chiamata Mac→101 e chiamata esterna reale, con app completamente terminata → notifica e audio funzionanti
2. Restart di Asterisk mentre il relay è attivo → riconnessione ARI automatica
3. Verifica manuale del flusso StasisStart→ring→push→device-ready→continue con un mock ARI locale prima del deploy in produzione

## Logo

Icona fornita: [`App-Logo.png`](App-Logo.png) — onda sonora che si trasforma in cornetta telefonica, cerchio di rete/casa, palette blu-teal.

Prompt usato per la generazione (riutilizzabile per varianti):

> Icona per app iOS di telefonia VoIP/SIP domestica. Un'onda sonora stilizzata che si trasforma in una cornetta telefonica minimalista, al centro di un piccolo simbolo di rete/casa. Stile flat moderno con leggera profondità/gradiente, palette blu-teal su sfondo pieno, linee pulite e geometriche, nessun testo, alto contrasto, leggibile anche a 60x60 px, adatto come app icon iOS full-bleed 1024x1024.
