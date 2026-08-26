#!/usr/bin/env bash
# ==============================================================================
# SCRIPT DE BACKUP AUTOMATIZADO - BOOKSTACK WIKI CORPORATIVO
# ==============================================================================
# Descrição: Realiza o dump consistente do MariaDB e arquivamento dos uploads,
#            anexos e configurações do BookStack, gerando pacote único compactado
#            com checksum SHA256 e rotação automática de 15 dias.
#
# Configuração Cron sugerida no host Linux (executar diariamente às 02:00 AM):
#   0 2 * * * /opt/bookstack/scripts/backup_bookstack.sh >> /var/log/bookstack_backup.log 2>&1
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. CORES E FORMATOS PARA LOGGING
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

log_info "Iniciando rotina de Backup do BookStack..."
log_info "Diretório do Projeto: ${PROJECT_ROOT}"

if [ ! -f "${ENV_FILE}" ]; then
    log_error "Arquivo .env não encontrado em: ${ENV_FILE}"
    exit 1
fi

# Carregar variáveis do .env (ignorando comentários e linhas vazias)
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

# Parâmetros padrão com fallback
DB_CONTAINER="bookstack_db"
DB_NAME="${DB_DATABASE:-bookstackapp}"
DB_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-}"
BACKUP_BASE_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-15}"

TIMESTAMP=$(date +'%Y%m%d_%H%M%S')
BACKUP_NAME="bookstack_backup_${TIMESTAMP}"
BACKUP_TARGET_DIR="${BACKUP_BASE_DIR}/${BACKUP_NAME}"
FINAL_ARCHIVE="${BACKUP_BASE_DIR}/${BACKUP_NAME}.tar.gz"

if [ -z "${DB_ROOT_PASS}" ]; then
    log_error "MYSQL_ROOT_PASSWORD não está definida no arquivo .env."
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. VERIFICAÇÃO DE PRÉ-REQUISITOS E STATUS DO BANCO
# ------------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || { log_error "Docker CLI não encontrada no host."; exit 1; }
command -v tar >/dev/null 2>&1 || { log_error "Utilitário 'tar' não encontrado no host."; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { log_error "Utilitário 'sha256sum' não encontrado no host."; exit 1; }

# Verificar se o container do MariaDB está em execução
if ! docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$"; then
    log_error "Container '${DB_CONTAINER}' não está em execução. Abortando backup."
    exit 1
fi

# Criar diretórios de trabalho
mkdir -p "${BACKUP_TARGET_DIR}"
mkdir -p "${BACKUP_BASE_DIR}"

# ------------------------------------------------------------------------------
# 4. EXECUÇÃO DO DUMP DO MARIADB
# ------------------------------------------------------------------------------
SQL_DUMP_FILE="${BACKUP_TARGET_DIR}/${DB_NAME}_${TIMESTAMP}.sql"
log_info "Exportando banco de dados '${DB_NAME}' a partir de '${DB_CONTAINER}'..."

# Executa o mariadb-dump de forma transacional e consistente
if docker exec "${DB_CONTAINER}" mariadb-dump \
    -u root \
    -p"${DB_ROOT_PASS}" \
    --single-transaction \
    --quick \
    --routines \
    --triggers \
    --events \
    "${DB_NAME}" > "${SQL_DUMP_FILE}"; then
    
    # Validar se o arquivo SQL não está vazio
    if [ ! -s "${SQL_DUMP_FILE}" ]; then
        log_error "O arquivo de dump SQL gerado está vazio. Abortando."
        rm -rf "${BACKUP_TARGET_DIR}"
        exit 1
    fi
    log_success "Dump do banco de dados concluído com sucesso ($(du -h "${SQL_DUMP_FILE}" | cut -f1))."
else
    log_error "Falha ao executar mariadb-dump no container ${DB_CONTAINER}."
    rm -rf "${BACKUP_TARGET_DIR}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. CÓPIA E ARQUIVAMENTO DOS DADOS DA APLICAÇÃO (Uploads/Anexos/Config)
# ------------------------------------------------------------------------------
APP_DATA_DIR="${PROJECT_ROOT}/data/app"
log_info "Compactando arquivos de aplicação e uploads de '${APP_DATA_DIR}'..."

if [ -d "${APP_DATA_DIR}" ]; then
    tar -czf "${BACKUP_TARGET_DIR}/app_storage_${TIMESTAMP}.tar.gz" -C "${PROJECT_ROOT}/data" app
    log_success "Armazenamento da aplicação copiado com sucesso ($(du -h "${BACKUP_TARGET_DIR}/app_storage_${TIMESTAMP}.tar.gz" | cut -f1))."
else
    log_warn "Diretório '${APP_DATA_DIR}' não encontrado. Apenas o banco foi arquivado."
fi

# Copiar arquivo .env (sem senhas descriptografadas no log)
cp "${ENV_FILE}" "${BACKUP_TARGET_DIR}/env_backup_${TIMESTAMP}.env"

# Criar manifesto do backup
cat <<EOF > "${BACKUP_TARGET_DIR}/manifest.json"
{
  "backup_name": "${BACKUP_NAME}",
  "timestamp": "${TIMESTAMP}",
  "bookstack_version": "$(docker exec bookstack_app php /app/www/artisan --version 2>/dev/null || echo 'unknown')",
  "database_name": "${DB_NAME}",
  "created_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
EOF

# ------------------------------------------------------------------------------
# 6. COMPACTAÇÃO FINAL E CHECKSUM
# ------------------------------------------------------------------------------
log_info "Gerando pacote final unificado: ${FINAL_ARCHIVE}..."
tar -czf "${FINAL_ARCHIVE}" -C "${BACKUP_BASE_DIR}" "${BACKUP_NAME}"
rm -rf "${BACKUP_TARGET_DIR}"

# Gerar Checksum SHA256 para garantia de integridade
log_info "Calculando checksum SHA256..."
sha256sum "${FINAL_ARCHIVE}" > "${FINAL_ARCHIVE}.sha256"

ARCHIVE_SIZE=$(du -h "${FINAL_ARCHIVE}" | cut -f1)
log_success "Backup concluído com sucesso: ${FINAL_ARCHIVE} (${ARCHIVE_SIZE})"
log_success "Checksum SHA256: $(cat "${FINAL_ARCHIVE}.sha256" | cut -d' ' -f1)"

# ------------------------------------------------------------------------------
# 7. ROTAÇÃO AUTOMÁTICA DE BACKUPS (RETENÇÃO DE 15 DIAS)
# ------------------------------------------------------------------------------
log_info "Executando política de retenção (expurgando backups com mais de ${RETENTION_DAYS} dias)..."

EXPIRED_COUNT=0
while IFS= read -r file; do
    if [ -n "$file" ]; then
        log_info "Removendo backup expirado: $file"
        rm -f "$file" "$file.sha256"
        EXPIRED_COUNT=$((EXPIRED_COUNT + 1))
    fi
done < <(find "${BACKUP_BASE_DIR}" -name "bookstack_backup_*.tar.gz" -type f -mtime +"${RETENTION_DAYS}")

log_info "Rotação finalizada. Arquivos expurgados: ${EXPIRED_COUNT}."
log_success "Processo de Backup do BookStack finalizado com êxito total!"
exit 0
