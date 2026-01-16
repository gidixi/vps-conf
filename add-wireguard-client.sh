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
print_warn "Incolla la configurazione del client WireGuard nel file:"
print_info "$WG_DIR/wg0.conf"
print_info ""
print_warn "Comandi manuali:"
print_info "  1. Crea/modifica il file:"
print_info "     sudo nano $WG_DIR/wg0.conf"
print_info ""
print_info "  2. Incolla la configurazione e salva (Ctrl+X, Y, INVIO)"
print_info ""
print_info "  3. Avvia la connessione:"
print_info "     sudo wg-quick up wg0"
print_info ""
print_info "  4. Verifica lo stato:"
print_info "     sudo wg show wg0"
print_info ""
print_info "  5. Per fermare:"
print_info "     sudo wg-quick down wg0"
print_info ""
print_info "Installazione WireGuard completata!"
