#!/bin/bash

# Script di configurazione WireGuard
# Installa e configura WireGuard VPN server
# Configura firewall per aprire porta 51820/udp
#
# Utilizzo:
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup-wireguard.sh | bash
#   oppure
#   wget -qO- https://raw.githubusercontent.com/USER/REPO/main/setup-wireguard.sh | bash

set -euo pipefail

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funzioni per log
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_question() {
    echo -e "${BLUE}[?]${NC} $1"
}

# Verifica che lo script sia eseguito come root o con sudo
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Questo script deve essere eseguito come root o con sudo"
        exit 1
    fi
    log_info "Verifica permessi: OK"
}

# Installa WireGuard se non presente
install_wireguard() {
    if command -v wg &> /dev/null; then
        log_warn "WireGuard è già installato"
        return
    fi
    
    log_info "Installazione WireGuard..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        wireguard \
        wireguard-tools \
        > /dev/null 2>&1
    
    log_info "WireGuard installato"
}

# Determina l'interfaccia di rete principale
get_main_interface() {
    # Prova a ottenere l'interfaccia dalla route di default
    local iface=$(ip route | grep default | awk '{print $5}' | head -1)
    
    if [[ -z "$iface" ]]; then
        # Fallback: cerca la prima interfaccia che non sia lo
        iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | head -1)
    fi
    
    if [[ -z "$iface" ]]; then
        log_error "Impossibile determinare l'interfaccia di rete principale"
        exit 1
    fi
    
    echo "$iface"
}

# Abilita IP forwarding
enable_ip_forwarding() {
    log_info "Abilitazione IP forwarding..."
    
    # Abilita immediatamente
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    
    # Abilita permanentemente
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        log_info "IP forwarding abilitato permanentemente"
    else
        log_warn "IP forwarding già configurato"
    fi
}

# Genera chiavi del server se non esistono
generate_server_keys() {
    local keys_dir="/etc/wireguard"
    
    if [[ -f "${keys_dir}/server_private.key" ]] && [[ -f "${keys_dir}/server_public.key" ]]; then
        log_warn "Chiavi del server già esistenti, non sovrascritte"
        return
    fi
    
    log_info "Generazione chiavi del server..."
    
    # Genera chiave privata e pubblica
    wg genkey | tee "${keys_dir}/server_private.key" | wg pubkey > "${keys_dir}/server_public.key"
    
    # Imposta permessi corretti
    chmod 600 "${keys_dir}/server_private.key"
    chmod 644 "${keys_dir}/server_public.key"
    
    log_info "Chiavi del server generate"
}

# Crea configurazione WireGuard
create_wireguard_config() {
    local config_file="/etc/wireguard/wg0.conf"
    local server_private_key
    local main_interface
    
    # Verifica se la configurazione esiste già
    if [[ -f "$config_file" ]]; then
        log_warn "Configurazione WireGuard già esistente: $config_file"
        log_warn "Non verrà sovrascritta. Se vuoi ricrearla, elimina il file prima."
        return
    fi
    
    log_info "Creazione configurazione WireGuard..."
    
    # Leggi la chiave privata
    server_private_key=$(cat /etc/wireguard/server_private.key)
    
    # Determina l'interfaccia principale
    main_interface=$(get_main_interface)
    log_info "Interfaccia di rete principale: $main_interface"
    
    # Crea la configurazione
    cat > "$config_file" <<EOF
[Interface]
# Indirizzo IP privato del server WireGuard
Address = 10.0.0.1/24
# Porta di ascolto
ListenPort = 51820
# Chiave privata del server
PrivateKey = $server_private_key
# Abilita forwarding IP e regole NAT
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $main_interface -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $main_interface -j MASQUERADE

# I client verranno aggiunti qui come sezioni [Peer]
# Esempio:
# [Peer]
# PublicKey = <chiave_pubblica_client>
# AllowedIPs = 10.0.0.2/32
EOF
    
    chmod 600 "$config_file"
    
    log_info "Configurazione creata: $config_file"
}

# Configura UFW per WireGuard
configure_ufw() {
    log_info "Configurazione firewall UFW..."
    
    # Verifica se UFW è installato
    if ! command -v ufw &> /dev/null; then
        log_warn "UFW non installato. Installa UFW per configurare il firewall."
        log_info "Per installare: apt-get install ufw"
        return
    fi
    
    # Abilita porta WireGuard
    if ufw status | grep -q "51820/udp"; then
        log_warn "Porta 51820/udp già configurata in UFW"
    else
        log_info "Apertura porta 51820/udp per WireGuard..."
        ufw allow 51820/udp comment 'WireGuard' > /dev/null 2>&1 || true
        log_info "Porta 51820/udp aperta in UFW"
    fi
    
    # Se UFW non è attivo, avvisa
    if ! ufw status | grep -q "Status: active"; then
        log_warn "UFW non è attivo. Per abilitarlo: ufw --force enable"
    fi
}

# Avvia e abilita WireGuard
start_wireguard() {
    log_info "Avvio servizio WireGuard..."
    
    # Ferma il servizio se già attivo
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        log_warn "WireGuard già attivo, riavvio..."
        systemctl stop wg-quick@wg0 > /dev/null 2>&1 || true
    fi
    
    # Abilita il servizio per l'avvio automatico
    systemctl enable wg-quick@wg0 > /dev/null 2>&1
    
    # Avvia il servizio
    if systemctl start wg-quick@wg0; then
        log_info "Servizio WireGuard avviato con successo"
    else
        log_error "Errore nell'avvio del servizio WireGuard"
        log_error "Verifica la configurazione: /etc/wireguard/wg0.conf"
        return 1
    fi
}

# Mostra informazioni finali
show_info() {
    local server_public_key
    local server_public_ip
    
    echo ""
    log_info "=== Configurazione WireGuard completata ==="
    echo ""
    
    # Verifica stato servizio
    if systemctl is-active --quiet wg-quick@wg0; then
        echo -e "  ${GREEN}✓${NC} Servizio WireGuard: attivo"
    else
        echo -e "  ${RED}✗${NC} Servizio WireGuard: non attivo"
    fi
    
    # Mostra informazioni interfaccia
    if ip link show wg0 &> /dev/null; then
        echo -e "  ${GREEN}✓${NC} Interfaccia wg0: attiva"
        ip addr show wg0 | grep -E "inet " | sed 's/^/    /'
    else
        echo -e "  ${RED}✗${NC} Interfaccia wg0: non trovata"
    fi
    
    # Mostra chiave pubblica del server
    if [[ -f /etc/wireguard/server_public.key ]]; then
        server_public_key=$(cat /etc/wireguard/server_public.key)
        echo ""
        log_info "Chiave pubblica del server:"
        echo "  $server_public_key"
    fi
    
    # Mostra IP pubblico del server
    server_public_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "N/A")
    echo ""
    log_info "IP pubblico del server: $server_public_ip"
    log_info "Porta WireGuard: 51820/udp"
    
    # Mostra informazioni WireGuard
    echo ""
    log_info "Stato WireGuard:"
    wg show 2>/dev/null || echo "  Nessuna interfaccia attiva"
    
    echo ""
    log_info "Prossimi passi:"
    echo "  1. Usa lo script add-wireguard-client.sh per aggiungere client"
    echo "  2. Oppure aggiungi manualmente sezioni [Peer] in /etc/wireguard/wg0.conf"
    echo "  3. Dopo ogni modifica, riavvia: systemctl restart wg-quick@wg0"
    echo ""
    log_info "File di configurazione: /etc/wireguard/wg0.conf"
    log_info "Chiavi salvate in: /etc/wireguard/"
    echo ""
}

# Main
main() {
    log_info "=== Script di configurazione WireGuard ==="
    echo ""
    
    check_root
    install_wireguard
    enable_ip_forwarding
    generate_server_keys
    create_wireguard_config
    configure_ufw
    start_wireguard
    show_info
    
    log_info "Configurazione completata con successo!"
}

# Esegui main
main "$@"
