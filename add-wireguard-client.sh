#!/bin/bash

# Script per installare e configurare WireGuard Client
# Utilizzo: curl -sSL https://raw.githubusercontent.com/USERNAME/REPO/main/install-wg-client.sh | sudo bash
# 
# Questo script installa WireGuard come CLIENT e configura una connessione VPN.
# Non richiede un server WireGuard configurato sul sistema.

set -e

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Funzione per stampare messaggi
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Verifica se lo script è eseguito come root
if [ "$EUID" -ne 0 ]; then 
    print_error "Per favore esegui lo script come root (usa sudo)"
    exit 1
fi

print_info "=== Script installazione WireGuard Client ==="
print_info "Questo script installerà WireGuard come CLIENT VPN"
print_info ""

# Rileva la distribuzione Linux
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    print_error "Impossibile rilevare la distribuzione Linux"
    exit 1
fi

# Installa WireGuard in base alla distribuzione
install_wireguard() {
    print_info "Rilevata distribuzione: $OS"
    
    case $OS in
        ubuntu|debian)
            print_info "Aggiornamento pacchetti..."
            apt-get update -qq
            
            print_info "Installazione WireGuard..."
            apt-get install -y wireguard wireguard-tools qrencode
            ;;
        fedora|rhel|centos)
            if [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
                print_info "Installazione EPEL repository..."
                yum install -y epel-release
            fi
            print_info "Installazione WireGuard..."
            yum install -y wireguard-tools qrencode
            ;;
        arch|manjaro)
            print_info "Installazione WireGuard..."
            pacman -S --noconfirm wireguard-tools qrencode
            ;;
        *)
            print_error "Distribuzione non supportata: $OS"
            print_info "Installa manualmente WireGuard e riprova"
            exit 1
            ;;
    esac
}

# Verifica se WireGuard è già installato
if command -v wg &> /dev/null; then
    print_warn "WireGuard è già installato"
    if wg --version &> /dev/null; then
        WG_VERSION=$(wg --version 2>&1 | head -1)
        print_info "Versione installata: $WG_VERSION"
    fi
else
    install_wireguard
fi

# Verifica che l'installazione sia andata a buon fine
if ! command -v wg &> /dev/null; then
    print_error "Installazione WireGuard fallita!"
    exit 1
fi

# Verifica che wg-quick sia disponibile
if ! command -v wg-quick &> /dev/null; then
    print_error "wg-quick non trovato. Reinstalla wireguard-tools."
    exit 1
fi

# Crea directory per le configurazioni se non esiste
WG_DIR="/etc/wireguard"
mkdir -p "$WG_DIR"

print_info ""
print_info "=========================================="
print_info "Configurazione WireGuard Client"
print_info "=========================================="
print_info ""

# Crea un file temporaneo per la configurazione
TEMP_CONFIG=$(mktemp /tmp/wg-config-XXXXXX.conf)
trap "rm -f $TEMP_CONFIG" EXIT

print_warn "Incolla la configurazione del client WireGuard qui sotto."
print_warn "Premi Ctrl+D quando hai finito di incollare (o Ctrl+Z su Windows, poi 'fg' e Ctrl+D)."
print_info ""

# Chiedi all'utente di incollare la configurazione
cat > "$TEMP_CONFIG"

# Leggi il contenuto del file temporaneo
CONFIG_CONTENT=$(cat "$TEMP_CONFIG")

# Verifica che la configurazione non sia vuota
CONFIG_CONTENT=$(echo "$CONFIG_CONTENT" | sed '/^[[:space:]]*$/d')  # Rimuovi righe vuote
if [ -z "$CONFIG_CONTENT" ]; then
    print_error "Nessuna configurazione fornita!"
    exit 1
fi

# Verifica che la configurazione contenga [Interface] e PrivateKey
if ! echo "$CONFIG_CONTENT" | grep -q "^\[Interface\]"; then
    print_error "Configurazione non valida: sezione [Interface] non trovata"
    exit 1
fi

if ! echo "$CONFIG_CONTENT" | grep -q "^PrivateKey"; then
    print_error "Configurazione non valida: PrivateKey non trovato"
    exit 1
fi

# Estrai il nome dell'interfaccia dal primo commento o usa un nome di default
CONFIG_NAME=$(echo "$CONFIG_CONTENT" | head -1 | grep -oP '#\s*\K\w+' 2>/dev/null || echo "")

# Se non trovato nel commento, prova a cercare un nome dopo [Interface]
if [ -z "$CONFIG_NAME" ]; then
    CONFIG_NAME=$(echo "$CONFIG_CONTENT" | grep -A 5 "^\[Interface\]" | grep -i "name\|interface" | head -1 | grep -oP '=\s*\K\w+' 2>/dev/null || echo "")
fi

# Rimuovi caratteri non validi dal nome
CONFIG_NAME=$(echo "$CONFIG_NAME" | tr -cd '[:alnum:]-_')
if [ -z "$CONFIG_NAME" ]; then
    CONFIG_NAME="wg0"
fi

CONFIG_FILE="$WG_DIR/${CONFIG_NAME}.conf"

# Verifica se il file esiste già
if [ -f "$CONFIG_FILE" ]; then
    print_warn "Il file $CONFIG_FILE esiste già."
    read -p "Vuoi sovrascriverlo? (s/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        print_info "Installazione annullata."
        exit 0
    fi
fi

# Salva la configurazione
print_info "Salvataggio configurazione in $CONFIG_FILE..."
echo "$CONFIG_CONTENT" > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

print_info "Configurazione salvata con successo!"

# Chiedi se avviare la connessione
print_info ""
read -p "Vuoi avviare la connessione WireGuard ora? (s/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Ss]$ ]]; then
    print_info "Avvio connessione WireGuard..."
    wg-quick up "$CONFIG_NAME"
    
    if [ $? -eq 0 ]; then
        print_info "Connessione WireGuard avviata con successo!"
        print_info "Interfaccia: $CONFIG_NAME"
        
        # Mostra lo stato
        print_info ""
        print_info "Stato connessione:"
        wg show "$CONFIG_NAME"
    else
        print_error "Errore nell'avvio della connessione WireGuard"
        exit 1
    fi
else
    print_info "Per avviare manualmente la connessione, usa:"
    print_info "  sudo wg-quick up $CONFIG_NAME"
fi

print_info ""
print_info "Comandi utili:"
print_info "  Avvia:   sudo wg-quick up $CONFIG_NAME"
print_info "  Ferma:   sudo wg-quick down $CONFIG_NAME"
print_info "  Stato:   sudo wg show $CONFIG_NAME"
print_info "  Log:     sudo journalctl -u wg-quick@$CONFIG_NAME -f"
print_info ""
print_info "Installazione completata!"
