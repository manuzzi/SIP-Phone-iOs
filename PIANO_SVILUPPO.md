# Piano di sviluppo — App SIP VoIP per iOS (uso domestico)

Client SIP nativo iOS per sostituire Linphone sull'interno `101`, con obiettivo di ricezione affidabile delle chiamate anche ad app sospesa/terminata, invio DTMF, e la miglior integrazione possibile con l'ecosistema nativo iOS (CallKit, Contatti, Siri).

Contesto infrastrutturale di riferimento: vedi [`.config.local/CONFIGURAZIONE.md`](.config.local/CONFIGURAZIONE.md) (Asterisk 20.8.1 su NanoPi R6S/FriendlyWRT, trunk Vodafone Business, interni PJSIP 100/101, WireGuard per accesso remoto).

## Decisioni architetturali

| Decisione | Scelta | Motivazione |
|---|---|---|
| Motore SIP/RTP | **Linphone SDK (liblinphone)**, integrato via Swift Package Manager | Esempi ufficiali CallKit+PushKit già pronti e mantenuti, coerenza con l'uso attuale di Linphone come client, evita di scrivere uno stack SIP/RTP da zero |
| Push relay (avviso APNs alla chiamata in arrivo) | Servizio containerizzato **Docker** sullo stesso NanoPi R6S | Docker è già installato sul router; nessun host aggiuntivo da gestire, immagine versionabile/aggiornabile |
| Interno di sviluppo/test | **Riuso diretto dell'interno 101** | `max_contacts=2` in `pjsip.conf` permette a Linphone e alla nuova app di essere registrati contemporaneamente: le chiamate in arrivo squillano su entrambi, zero rischio di interrompere la telefonia funzionante |
| Videochiamate | **Fuori scope** (solo audio) | Coerente con l'uso attuale (telefonia fissa + interni); Linphone SDK supporta comunque video se servisse in futuro |
| Cifratura SIP/RTP | **Invariata** (UDP in chiaro, no TLS/SRTP) | Il traffico remoto è già protetto dal tunnel WireGuard; nessuna modifica lato Asterisk per restare nello scope minimo |
| Distribuzione | App personale, architettura pulita (no credenziali hardcoded), eventuale apertura futura da valutare | Vedi nota licenza SDK sotto |

**Nota licenza SDK (da rivalutare prima di M6):** Linphone SDK è distribuito in dual-license GPLv3 / commerciale. Uso personale (installazione diretta via Xcode/TestFlight privato) non pone alcun vincolo. Una eventuale pubblicazione pubblica su App Store richiederebbe però rilasciare il codice sorgente dell'app sotto GPLv3, oppure acquistare una licenza commerciale da Belledonne Communications.

## Architettura

```
iPhone (app SIP)                    NanoPi R6S / FriendlyWRT
┌─────────────────────┐            ┌──────────────────────────┐
│ Linphone SDK          │  SIP/RTP  │ Asterisk 20.8.1            │
│ (liblinphone)         │◄──UDP────►│  interno 101 (riusato)     │
│ CallKit + PushKit      │  :5060    │  AMI (nuovo, localhost)    │
│ Intents Extension      │           └──────────┬─────────────────┘
└─────────▲─────────────┘                       │ evento DialBegin→101
          │ VoIP Push (APNs)          ┌──────────▼─────────────┐
          └───────────────────────────┤ Push relay (Docker, Go)  │
                                       │  client AMI + APNs API   │
                                       └───────────────────────────┘
```

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

### M2 — Affidabilità in background: PushKit + push relay
- Abilitazione AMI su Asterisk (`manager.conf`, utente dedicato read-only, bind solo `127.0.0.1`)
- Push relay containerizzato (Go, immagine minimale, `network_mode: host`) che ascolta eventi `DialBegin` verso `PJSIP/101-*` e invia VoIP Push via APNs (auth key `.p8`, topic `<bundle-id>.voip`)
- Dedup per `Uniqueid` sorgente (il forking su più contatti dell'aor 101 genera più `DialBegin` per la stessa chiamata logica)
- Endpoint locale di registrazione device token (protetto da bearer secret, accessibile solo da LAN/WireGuard)
- App: gestione PushKit → `reportNewIncomingCall` immediato → completamento registrazione/gestione INVITE
- WireGuard iOS in modalità on-demand/always-on per garantire raggiungibilità di `192.168.1.1` all'arrivo del push
- **Validazione:** chiamata ricevuta con successo in foreground, background, app terminata (swipe-killed), telefono bloccato, sia su WiFi casa sia fuori casa via cellulare+VPN; squillo entro pochi secondi dall'INVITE reale

### M3 — DTMF e funzionalità in chiamata
- Tastierino DTMF in-call (RFC4733, già configurato lato Asterisk con `dtmf_mode=rfc4733`)
- Supporto DTMF anche dalla UI di sistema CallKit (`CXPlayDTMFCallAction`)
- Test contro un risponditore automatico reale
- **Validazione:** cifre riconosciute correttamente dal risponditore, nessun problema di timing o invii doppi

### M4 — Integrazione con Contatti/Siri
- Intents Extension (`INStartCallIntent`) per comparire come opzione di chiamata nei Contatti iOS
- Chiamate visibili nei Recenti di sistema, comando Siri "Chiama [nome] con [App]"
- Valutazione facoltativa della funzione "app di chiamata predefinita" (iOS 18+)
- *Nota: non è possibile intercettare il tastierino dell'app Telefono nativa per numeri PSTN generici — questa è la forma di integrazione più vicina realizzabile su iOS.*
- **Validazione:** dall'app Contatti tocchi l'icona dell'app su un contatto e parte la chiamata SIP; la chiamata compare nei Recenti di sistema

### M5 — Robustezza e uso quotidiano
- Gestione cambio rete (WiFi casa ↔ cellulare+VPN ↔ perdita connessione) con ri-registrazione automatica
- Notifiche locali se il server non è raggiungibile
- Test sul campo di 1-2 settimane come sostituto quotidiano di Linphone, con log delle chiamate perse
- **Validazione:** zero chiamate perse nel periodo di test, comportamento stabile su riavvii di telefono/app update

### M6 — Opzionale, solo se si decide di procedere verso l'App Store
- Rimozione di eventuali residui hardcoded
- Risoluzione della questione di licenza SDK (GPL vs licenza commerciale Belledonne)
- Revisione requisiti App Review per app CallKit/VoIP, naming/branding non legato a Vodafone o dati personali
- Distribuzione TestFlight pubblica o submission

## Dettaglio push relay (M2)

### Container e networking
`network_mode: host` invece del bridge Docker di default: su OpenWrt il bridge interagisce in modo imprevedibile con `fw4`/`nftables`, e il servizio non deve esporre porte verso l'esterno — solo connessioni in uscita verso Asterisk (localhost) e APNs.

### Configurazione AMI (`/etc/asterisk/manager.conf`)
```ini
[general]
enabled = yes
port = 5038
bindaddr = 127.0.0.1

[pushrelay]
secret = <secret-random-forte>
read = call,dialplan
write =
permit = 127.0.0.1/255.255.255.255
```
Nessuna modifica a `extensions.conf`: il relay è un puro osservatore passivo.

### Rilevamento chiamata
Ascolto evento `DialBegin`, filtro su `DestChannel` che inizia con `PJSIP/101-`. Dedup per `Uniqueid` del canale sorgente con finestra di debounce (~8s), dato che un singolo `Dial(PJSIP/101,25)` forka su tutti i contatti registrati dell'aor.

### VoIP Push (APNs)
- Auth key `.p8` token-based (JWT ES256, claims `iss=<Team ID>`, `kid=<Key ID>`, rigenerato ogni ~50 min)
- `POST https://api.push.apple.com/3/device/<token>` (sandbox per build di sviluppo)
- Header: `apns-topic: <bundle-id>.voip`, `apns-push-type: voip`, `apns-priority: 10`, `apns-expiration` breve (~30s)
- Payload minimale: `{"callId": "<uuid>", "callerNumber": "...", "callerName": "...", "ts": <epoch>}`

### Registrazione device token
```
POST /register-token
Authorization: Bearer <shared-secret>
{"deviceToken": "..."}
```
Token persistito su volume Docker montato, non nell'immagine.

### Deployment
Dockerfile multi-stage (build Go arm64 → immagine finale `distroless/static`), `docker-compose.yml` con `restart: unless-stopped`, log con `max-size`/`max-file` per non riempire la flash del router. Verificare `/etc/init.d/dockerd enable` per il riavvio automatico dopo reboot del router.

### Resilienza
- Riconnessione AMI con backoff esponenziale e ri-login automatico
- Gestione errori APNs (`410 Unregistered` → invalida token salvato; errori di firma/topic → log di alta severità)
- Endpoint `/healthz` che riflette lo stato della connessione AMI

### Test specifici
1. Chiamata reale verso 101 con relay attivo → push ricevuta entro ~200ms dall'INVITE
2. Restart di Asterisk mentre il relay è attivo → riconnessione automatica
3. Restart del router → Docker e container ripartono da soli
4. Linphone + nuova app entrambi registrati su 101 → una sola push (dedup funzionante) nonostante il forking

## Logo

Icona fornita: [`App-Logo.png`](App-Logo.png) — onda sonora che si trasforma in cornetta telefonica, cerchio di rete/casa, palette blu-teal.

Prompt usato per la generazione (riutilizzabile per varianti):

> Icona per app iOS di telefonia VoIP/SIP domestica. Un'onda sonora stilizzata che si trasforma in una cornetta telefonica minimalista, al centro di un piccolo simbolo di rete/casa. Stile flat moderno con leggera profondità/gradiente, palette blu-teal su sfondo pieno, linee pulite e geometriche, nessun testo, alto contrasto, leggibile anche a 60x60 px, adatto come app icon iOS full-bleed 1024x1024.
