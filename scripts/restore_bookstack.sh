#!/usr/bin/env bash
# ==============================================================================
# SCRIPT DE RESTAURAÇÃO (DISASTER RECOVERY) - BOOKSTACK WIKI CORPORATIVO
# ==============================================================================
# Descrição: Procedimento guiado e seguro para restauração completa da base de
#            dados MariaDB e do sistema de arquivos do BookStack a partir de um
#            pacote de backup '.tar.gz'.
#
# Uso:
#   sudo ./restore_bookstack.sh /caminho/do/backup/bookstack_backup_YYYYMMDD_HHMMSS.tar.gz
#   (ou execute sem argumentos para escolher o backup mais recente de forma interativa)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. CORES E FORMATOS
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${RED}[ERROR]${NC} $*" >&2; }

# ------------------------------------------------------------------------------
# 2. DEFINIÇÃO DE CAMINHOS E CARREGAMENTO DE VARIÁVEIS
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

echo -e "${BOLD}==============================================================================${NC}"
echo -e "${BOLD}           BOOKSTACK CORPORATIVO - ASSISTENTE DE RESTAURAÇÃO (DR)             ${NC}"
echo -e "${BOLD}==============================================================================${NC}\n"

if [ ! -f "${ENV_FILE}" ]; then
    log_error "Arquivo .env não encontrado em: ${ENV_FILE}"
    exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

DB_CONTAINER="bookstack_db"
APP_CONTAINER="bookstack_app"
DB_NAME="${DB_DATABASE:-bookstackapp}"
DB_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-}"
BACKUP_BASE_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/backups}"

# ------------------------------------------------------------------------------
# 3. SELEÇÃO DO ARQUIVO DE BACKUP
# ------------------------------------------------------------------------------
BACKUP_ARCHIVE="${1:-}"

if [ -z "${BACKUP_ARCHIVE}" ]; then
    log_info "Buscando backups disponíveis em '${BACKUP_BASE_DIR}'..."
    if [ ! -d "${BACKUP_BASE_DIR}" ]; then
        log_error "Diretório de backup '${BACKUP_BASE_DIR}' não existe."
        exit 1
    fi

    LATEST_BACKUP=$(find "${BACKUP_BASE_DIR}" -name "bookstack_backup_*.tar.gz" -type f | sort -r | head -n 1)
    if [ -z "${LATEST_BACKUP}" ]; then
        log_error "Nenhum arquivo de backup encontrado em ${BACKUP_BASE_DIR}."
        exit 1
    fi

    echo -e "Backup mais recente encontrado:"
    echo -e "  -> ${YELLOW}${LATEST_BACKUP}${NC}\n"
    read -rp "Deseja restaurar este arquivo? [S/n] ou digite o caminho completo: " USER_INPUT
    USER_INPUT=${USER_INPUT:-S}

    if [[ "${USER_INPUT}" =~ ^[Ss]$ ]]; then
        BACKUP_ARCHIVE="${LATEST_BACKUP}"
    elif [ -f "${USER_INPUT}" ]; then
        BACKUP_ARCHIVE="${USER_INPUT}"
    else
        log_error "Arquivo especificado inválido ou operação cancelada pelo usuário."
        exit 1
    fi
fi

if [ ! -f "${BACKUP_ARCHIVE}" ]; then
    log_error "Arquivo de backup não encontrado: ${BACKUP_ARCHIVE}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. VALIDAÇÃO DE CHECKSUM SHA256 (SE DISPONÍVEL)
# ------------------------------------------------------------------------------
SHA_FILE="${BACKUP_ARCHIVE}.sha256"
if [ -f "${SHA_FILE}" ]; then
    log_info "Validando integridade do arquivo via SHA256..."
    if sha256sum -c "${SHA_FILE}" >/dev/null 2>&1; then
        log_success "Integridade do arquivo confirmada com sucesso!"
    else
        log_error "FALHA NA CHECAGEM DE INTEGRIDADE SHA256! O arquivo pode estar corrompido."
        read -rp "Deseja continuar mesmo assim por sua conta e risco? (digite 'FORCAR'): " FORCE_INPUT
        if [ "${FORCE_INPUT}" != "FORCAR" ]; then
            log_error "Restauração cancelada."
            exit 1
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 5. CONFIRMAÇÃO CRÍTICA DE SEGURANÇA
# ------------------------------------------------------------------------------
echo -e "\n${RED}${BOLD}============================== ATENÇÃO CRÍTICA ==============================${NC}"
echo -e "${RED}Esta operação irá SOBRESCREVER completamente os dados atuais do banco de dados${NC}"
echo -e "${RED}'${DB_NAME}' e os arquivos de upload do BookStack!${NC}"
echo -e "${RED}${BOLD}==============================================================================${NC}\n"

read -rp "Para confirmar a restauração, digite 'RESTAURAR': " CONFIRM
if [ "${CONFIRM}" != "RESTAURAR" ]; then
    log_warn "Operação cancelada pelo usuário."
    exit 0
fi

# ------------------------------------------------------------------------------
# 6. PREPARAÇÃO DO AMBIENTE TEMPORÁRIO
# ------------------------------------------------------------------------------
TEMP_RESTORE_DIR=$(mktemp -d /tmp/bookstack_restore_XXXXXX)
# Garantir limpeza da pasta temporária ao sair
trap 'rm -rf "${TEMP_RESTORE_DIR}"' EXIT

log_info "Extraindo pacote de backup em diretório temporário: ${TEMP_RESTORE_DIR}..."
tar -xzf "${BACKUP_ARCHIVE}" -C "${TEMP_RESTORE_DIR}"

# Localizar a pasta interna descompactada
EXTRACTED_FOLDER=$(find "${TEMP_RESTORE_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n 1)
if [ -z "${EXTRACTED_FOLDER}" ]; then
    log_error "Falha na estrutura do arquivo de backup descompactado."
    exit 1
fi

# Exibir manifesto se existir
if [ -f "${EXTRACTED_FOLDER}/manifest.json" ]; then
    log_info "Manifesto do backup encontrado:"
    cat "${EXTRACTED_FOLDER}/manifest.json"
    echo ""
fi

# ------------------------------------------------------------------------------
# 7. PARADA DA APLICAÇÃO E VALIDAÇÃO DO BANCO
# ------------------------------------------------------------------------------
log_info "Interrompendo container web '${APP_CONTAINER}' para evitar conexões ativas..."
cd "${PROJECT_ROOT}"
docker compose stop bookstack || true

log_info "Garantindo que o banco de dados '${DB_CONTAINER}' esteja em execução..."
docker compose up -d bookstack_db

log_info "Aguardando estabilidade do banco de dados (healthcheck)..."
until docker exec "${DB_CONTAINER}" mariadb-admin ping -h localhost -u root -p"${DB_ROOT_PASS}" --silent >/dev/null 2>&1; do
    echo -n "."
    sleep 2
done
echo ""
log_success "Banco de dados pronto para restauração."

# ------------------------------------------------------------------------------
# 8. RESTAURAÇÃO DO BANCO DE DADOS MARIADB
# ------------------------------------------------------------------------------
SQL_FILE=$(find "${EXTRACTED_FOLDER}" -name "*.sql" | head -n 1)

if [ -f "${SQL_FILE}" ]; then
    log_info "Restaurando base de dados a partir de '$(basename "${SQL_FILE}")'..."
    
    # Recriar e importar banco
    docker exec -i "${DB_CONTAINER}" mariadb -u root -p"${DB_ROOT_PASS}" -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    
    if docker exec -i "${DB_CONTAINER}" mariadb -u root -p"${DB_ROOT_PASS}" "${DB_NAME}" < "${SQL_FILE}"; then
        log_success "Base de dados restaurada com sucesso!"
    else
        log_error "Erro durante a importação SQL no MariaDB."
        exit 1
    fi
else
    log_warn "Nenhum arquivo .sql encontrado no backup. Pulando restauração de banco."
fi

# ------------------------------------------------------------------------------
# 9. RESTAURAÇÃO DOS ARQUIVOS DA APLICAÇÃO (UPLOADS / CONFIG)
# ------------------------------------------------------------------------------
APP_STORAGE_ARCHIVE=$(find "${EXTRACTED_FOLDER}" -name "app_storage_*.tar.gz" | head -n 1)

if [ -f "${APP_STORAGE_ARCHIVE}" ]; then
    log_info "Restaurando arquivos de storage e uploads em '${PROJECT_ROOT}/data'..."
    mkdir -p "${PROJECT_ROOT}/data"
    tar -xzf "${APP_STORAGE_ARCHIVE}" -C "${PROJECT_ROOT}/data"
    
    # Ajustar permissões com base no PUID/PGID do .env
    USER_ID="${PUID:-1000}"
    GROUP_ID="${PGID:-1000}"
    log_info "Ajustando propriedade dos arquivos para ${USER_ID}:${GROUP_ID}..."
    if command -v chown >/dev/null 2>&1; then
        chown -R "${USER_ID}:${GROUP_ID}" "${PROJECT_ROOT}/data/app" 2>/dev/null || true
    fi
    log_success "Arquivos de aplicação restaurados com sucesso!"
fi

# ------------------------------------------------------------------------------
# 10. REINICIALIZAÇÃO E TESTE DE SAÚDE DOS SERVIÇOS
# ------------------------------------------------------------------------------
log_info "Reiniciando stack do BookStack..."
docker compose up -d

log_info "Aguardando inicialização do BookStack..."
sleep 10

if docker ps | grep -q "${APP_CONTAINER}"; then
    log_success "Container '${APP_CONTAINER}' está ativo e em execução!"
else
    log_error "Container '${APP_CONTAINER}' não subiu corretamente. Verifique: docker compose logs bookstack"
    exit 1
fi

echo -e "\n${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}         RESTAURAÇÃO DO BOOKSTACK CONCLUÍDA COM ÊXITO TOTAL!                  ${NC}"
echo -e "${BOLD}==============================================================================${NC}"
echo -e "Acesse o BookStack em: ${BLUE}${APP_URL:-http://localhost:6875}${NC}"
echo -e "Verifique se seus POPs, anexos e usuários estão operacionais.\n"
exit 0
