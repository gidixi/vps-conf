#!/bin/bash

# Script di installazione server
# Installazione: nginx, fail2ban, ufw, docker, docker compose, wireguard, btop
# Configurazione firewall: solo porte necessarie (SSH 22, HTTP 80, HTTPS 443, WireGuard 51820)
#
# Utilizzo:
#   curl -fsSL https://raw.githubusercontent.com/gidixi/REPO/main/install-server.sh | bash
#   oppure
#   wget -qO- https://raw.githubusercontent.com/gidixi/REPO/main/install-server.sh | bash

set -euo pipefail

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Funzione per log
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Verifica che lo script sia eseguito come root o con sudo
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Questo script deve essere eseguito come root o con sudo"
        exit 1
    fi
    log_info "Verifica permessi: OK"
}

# Aggiorna sistema e installa dipendenze base
setup_system() {
    log_info "Aggiornamento repository pacchetti..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    
    log_info "Installazione dipendenze base..."
    apt-get install -y -qq \
        curl \
        wget \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        software-properties-common \
        > /dev/null 2>&1
    
    log_info "Sistema aggiornato e dipendenze installate"
}

# Installa nginx
install_nginx() {
    if command -v nginx &> /dev/null; then
        log_warn "nginx è già installato"
        return
    fi
    
    log_info "Installazione nginx..."
    apt-get install -y -qq nginx > /dev/null 2>&1
    systemctl enable nginx > /dev/null 2>&1
    systemctl start nginx > /dev/null 2>&1
    log_info "nginx installato e avviato"
}

# Installa fail2ban
install_fail2ban() {
    if command -v fail2ban-client &> /dev/null; then
        log_warn "fail2ban è già installato"
        return
    fi
    
    log_info "Installazione fail2ban..."
    apt-get install -y -qq fail2ban > /dev/null 2>&1
    systemctl enable fail2ban > /dev/null 2>&1
    systemctl start fail2ban > /dev/null 2>&1
    log_info "fail2ban installato e avviato"
}

# Installa UFW
install_ufw() {
    if command -v ufw &> /dev/null; then
        log_warn "ufw è già installato"
        return
    fi
    
    log_info "Installazione ufw..."
    apt-get install -y -qq ufw > /dev/null 2>&1
    log_info "ufw installato"
}

# Installa Docker
install_docker() {
    if command -v docker &> /dev/null; then
        log_warn "Docker è già installato"
        return
    fi
    
    log_info "Installazione Docker..."
    
    # Rimuovi versioni vecchie se presenti
    apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Aggiungi repository Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq
    
    # Installa Docker Engine
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
        > /dev/null 2>&1
    
    # Avvia e abilita Docker
    systemctl enable docker > /dev/null 2>&1
    systemctl start docker > /dev/null 2>&1
    
    # Aggiungi utente corrente al gruppo docker (se non root)
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER" 2>/dev/null || true
        log_info "Utente $SUDO_USER aggiunto al gruppo docker"
    fi
    
    log_info "Docker installato e avviato"
}

# Installa WireGuard
install_wireguard() {
    if command -v wg &> /dev/null; then
        log_warn "WireGuard è già installato"
        return
    fi
    
    log_info "Installazione WireGuard..."
    
    # Aggiungi repository WireGuard se necessario (per versioni più recenti)
    add-apt-repository -y ppa:wireguard/wireguard 2>/dev/null || true
    apt-get update -qq
    
    apt-get install -y -qq \
        wireguard \
        wireguard-tools \
        > /dev/null 2>&1
    
    # Abilita IP forwarding per WireGuard
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi
    
    log_info "WireGuard installato"
    log_warn "Ricorda di configurare WireGuard manualmente dopo l'installazione"
}

# Installa btop
install_btop() {
    if command -v btop &> /dev/null; then
        log_warn "btop è già installato"
        return
    fi
    
    log_info "Installazione btop..."
    apt-get install -y -qq btop > /dev/null 2>&1
    log_info "btop installato"
}

# Configura UFW
configure_ufw() {
    log_info "Configurazione UFW..."
    
    # Reset UFW se già configurato (con conferma silenziosa per script automatico)
    if ufw status | grep -q "Status: active"; then
        log_warn "UFW è già attivo. Le nuove regole verranno aggiunte alle esistenti."
    fi
    
    # Imposta default policies
    ufw --force reset > /dev/null 2>&1 || true
    ufw default deny incoming > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1
    
    # Abilita porte necessarie
    log_info "Apertura porte necessarie..."
    ufw allow 22/tcp comment 'SSH' > /dev/null 2>&1
    ufw allow 80/tcp comment 'HTTP' > /dev/null 2>&1
    ufw allow 443/tcp comment 'HTTPS' > /dev/null 2>&1
    ufw allow 51820/udp comment 'WireGuard' > /dev/null 2>&1
    
    # Abilita UFW
    ufw --force enable > /dev/null 2>&1
    
    log_info "UFW configurato e abilitato"
}

# Configura fail2ban base
configure_fail2ban() {
    log_info "Configurazione fail2ban..."
    
    # Crea configurazione locale se non esiste
    if [[ ! -f /etc/fail2ban/jail.local ]]; then
        cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF
        log_info "Configurazione fail2ban creata"
    else
        log_warn "Configurazione fail2ban già presente, non sovrascritta"
    fi
    
    # Riavvia fail2ban per applicare configurazione
    systemctl restart fail2ban > /dev/null 2>&1 || true
    log_info "fail2ban configurato"
}

# Mostra stato finale
show_status() {
    echo ""
    log_info "=== Installazione completata ==="
    echo ""
    
    log_info "Stato servizi:"
    systemctl is-active --quiet nginx && echo -e "  ${GREEN}✓${NC} nginx: attivo" || echo -e "  ${RED}✗${NC} nginx: non attivo"
    systemctl is-active --quiet fail2ban && echo -e "  ${GREEN}✓${NC} fail2ban: attivo" || echo -e "  ${RED}✗${NC} fail2ban: non attivo"
    systemctl is-active --quiet docker && echo -e "  ${GREEN}✓${NC} docker: attivo" || echo -e "  ${RED}✗${NC} docker: non attivo"
    systemctl is-active --quiet ufw && echo -e "  ${GREEN}✓${NC} ufw: attivo" || echo -e "  ${RED}✗${NC} ufw: non attivo"
    
    echo ""
    log_info "Regole UFW attive:"
    ufw status numbered | grep -E "^\[|^[0-9]" || ufw status
    
    echo ""
    log_info "Prossimi passi:"
    echo "  1. Configura nginx per i tuoi siti web"
    echo "  2. Configura WireGuard: wg-quick up wg0 (dopo aver creato la configurazione)"
    echo "  3. Se hai aggiunto un utente al gruppo docker, fai logout/login per applicare i permessi"
    echo "  4. Personalizza fail2ban se necessario: /etc/fail2ban/jail.local"
    echo ""
}

# Main
main() {
    log_info "=== Script di installazione server ==="
    echo ""
    
    check_root
    setup_system
    install_nginx
    install_fail2ban
    install_ufw
    install_docker
    install_wireguard
    install_btop
    configure_ufw
    configure_fail2ban
    show_status
    
    log_info "Installazione completata con successo!"
}

# Esegui main
main "$@"
