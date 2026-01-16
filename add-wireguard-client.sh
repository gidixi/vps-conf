#!/bin/bash

# Script per aggiungere un client WireGuard
# Genera chiavi, crea configurazione client e aggiunge peer al server

set -euo pipefail

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funzioni per log (scrivono su stderr per non interferire con output catturato)
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_question() {
    echo -e "${BLUE}[?]${NC} $1" >&2
}

# Verifica che lo script sia eseguito come root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Questo script deve essere eseguito come root o con sudo"
        exit 1
    fi
}

# Verifica che WireGuard sia configurato
check_wireguard() {
    if [[ ! -f /etc/wireguard/wg0.conf ]]; then
        log_error "WireGuard non è configurato. Configura prima il server."
        exit 1
    fi
    
    if [[ ! -f /etc/wireguard/server_public.key ]]; then
        log_error "Chiave pubblica del server non trovata."
        exit 1
    fi
}

# Trova il prossimo IP disponibile
get_next_ip() {
    local base_ip="10.0.0"
    local start=2
    local end=254
    
    # Estrae tutti gli IP già usati dal file di configurazione
    local used_ips=$(grep -oP "10\.0\.0\.\d+" /etc/wireguard/wg0.conf 2>/dev/null | sort -u || true)
    
    for i in $(seq $start $end); do
        local ip="${base_ip}.${i}"
        if ! echo "$used_ips" | grep -q "^${ip}$"; then
            echo "$ip"
            return 0
        fi
    done
    
    log_error "Nessun IP disponibile nella rete 10.0.0.0/24"
    exit 1
}

# Genera chiavi per il client
generate_client_keys() {
    local client_name=$1
    local keys_dir="/etc/wireguard/clients"
    
    mkdir -p "$keys_dir"
    
    log_info "Generazione chiavi per il client $client_name..."
    
    # Genera chiave privata
    wg genkey | tee "${keys_dir}/${client_name}_private.key" | wg pubkey > "${keys_dir}/${client_name}_public.key"
    
    # Imposta permessi corretti
    chmod 600 "${keys_dir}/${client_name}_private.key"
    chmod 644 "${keys_dir}/${client_name}_public.key"
    
    echo "${keys_dir}/${client_name}_private.key"
}

# Legge la chiave pubblica del server
get_server_public_key() {
    cat /etc/wireguard/server_public.key
}

# Ottiene l'IP pubblico del server
get_server_public_ip() {
    # Prova a ottenere l'IP pubblico dalla configurazione o dal sistema
    local server_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "")
    
    if [[ -z "$server_ip" ]]; then
        log_warn "Impossibile determinare automaticamente l'IP pubblico del server"
        log_question "Inserisci l'IP pubblico del server (o premi Invio per usare 194.5.152.237): "
        read -r server_ip
        server_ip=${server_ip:-194.5.152.237}
    fi
    
    echo "$server_ip"
}

# Crea la configurazione del client
create_client_config() {
    local client_name=$1
    local client_ip=$2
    local client_private_key=$3
    local server_public_key=$4
    local server_public_ip=$5
    local server_port=${6:-51820}
    
    local config_dir="/etc/wireguard/clients"
    local config_file="${config_dir}/${client_name}.conf"
    
    log_info "Creazione configurazione client: $config_file"
    
    cat > "$config_file" <<EOF
[Interface]
# Nome client: $client_name
PrivateKey = $(cat "$client_private_key")
Address = ${client_ip}/32
DNS = 8.8.8.8, 8.8.4.4

[Peer]
# Server WireGuard
PublicKey = $server_public_key
Endpoint = ${server_public_ip}:${server_port}
AllowedIPs = 10.0.0.0/24, 0.0.0.0/0
PersistentKeepalive = 25
EOF
    
    chmod 600 "$config_file"
    
    echo "$config_file"
}

# Aggiunge il peer al server
add_peer_to_server() {
    local client_name=$1
    local client_public_key=$2
    local client_ip=$3
    
    local server_config="/etc/wireguard/wg0.conf"
    
    log_info "Aggiunta peer al server..."
    
    # Aggiunge il peer alla fine del file
    cat >> "$server_config" <<EOF

# Client: $client_name
[Peer]
PublicKey = $client_public_key
AllowedIPs = ${client_ip}/32
EOF
    
    log_info "Peer aggiunto al server"
}

# Riavvia WireGuard
restart_wireguard() {
    log_info "Riavvio servizio WireGuard..."
    if systemctl restart wg-quick@wg0; then
        log_info "Servizio WireGuard riavviato con successo"
    else
        log_error "Errore nel riavvio del servizio WireGuard"
        return 1
    fi
}

# Mostra il QR code (se qrencode è installato)
show_qrcode() {
    local config_file=$1
    
    if command -v qrencode &> /dev/null; then
        log_info "Generazione QR code..."
        echo ""
        qrencode -t ANSIUTF8 < "$config_file"
        echo ""
    else
        log_warn "qrencode non installato. Installa con: apt-get install qrencode"
    fi
}

# Main
main() {
    echo ""
    log_info "=== Script aggiunta client WireGuard ==="
    echo ""
    
    check_root
    check_wireguard
    
    # Chiedi il nome del client
    log_question "Inserisci il nome del client (es: laptop, phone, desktop): "
    read -r client_name
    
    if [[ -z "$client_name" ]]; then
        log_error "Il nome del client non può essere vuoto"
        exit 1
    fi
    
    # Verifica che il client non esista già
    if [[ -f "/etc/wireguard/clients/${client_name}.conf" ]]; then
        log_warn "Un client con nome '$client_name' esiste già"
        log_question "Vuoi sovrascriverlo? (s/N): "
        read -r overwrite
        if [[ ! "$overwrite" =~ ^[sS]$ ]]; then
            log_info "Operazione annullata"
            exit 0
        fi
    fi
    
    # Ottieni il prossimo IP disponibile
    client_ip=$(get_next_ip)
    log_info "IP assegnato al client: $client_ip"
    
    # Genera chiavi
    client_private_key=$(generate_client_keys "$client_name")
    client_public_key=$(cat "${client_private_key/_private.key/_public.key}")
    
    # Ottieni informazioni del server
    server_public_key=$(get_server_public_key)
    server_public_ip=$(get_server_public_ip)
    
    # Chiedi la porta (opzionale)
    log_question "Porta WireGuard del server (default: 51820): "
    read -r server_port
    server_port=${server_port:-51820}
    
    # Crea configurazione client
    config_file=$(create_client_config "$client_name" "$client_ip" "$client_private_key" "$server_public_key" "$server_public_ip" "$server_port")
    
    # Aggiungi peer al server
    add_peer_to_server "$client_name" "$client_public_key" "$client_ip"
    
    # Riavvia WireGuard
    if ! restart_wireguard; then
        log_error "Errore nel riavvio. Verifica la configurazione manualmente."
        exit 1
    fi
    
    # Mostra riepilogo
    echo ""
    log_info "=== Client creato con successo ==="
    echo ""
    echo -e "  ${GREEN}Nome client:${NC} $client_name"
    echo -e "  ${GREEN}IP client:${NC} $client_ip"
    echo -e "  ${GREEN}File configurazione:${NC} $config_file"
    echo -e "  ${GREEN}Chiave pubblica client:${NC} $client_public_key"
    echo ""
    
    # Mostra il contenuto del file di configurazione
    log_info "Configurazione client:"
    echo ""
    cat "$config_file"
    echo ""
    
    # Mostra QR code se disponibile
    show_qrcode "$config_file"
    
    log_info "Per trasferire la configurazione al client:"
    echo "  - Copia il file: $config_file"
    echo "  - Oppure mostra il QR code e scansionalo con l'app WireGuard"
    echo ""
    log_info "Per installare su Android/iOS, importa il file .conf nell'app WireGuard"
    echo ""
}

# Esegui main
main "$@"
