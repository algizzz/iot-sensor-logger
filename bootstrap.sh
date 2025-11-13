#!/bin/bash

# ==============================================================================
# Простой bootstrap-скрипт для первоначальной настройки сервера
# ==============================================================================

set -euo pipefail

# --- Конфигурация ---
readonly REPO_URL="https://github.com/algizzz/iot-sensor-logger.git"
readonly INSTALL_DIR="/opt/iot-sensor-logger"

# --- Цвета для логов ---
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # Без цвета

# --- Функции логирования ---
log_info() { echo -e "${GREEN}[ИНФО]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} $*"; }
log_error() { echo -e "${RED}[ОШИБКА]${NC} $*"; }

# --- Основные функции ---

# Проверка прав суперпользователя
check_root() {
    log_info "Проверка прав суперпользователя..."
    if [ "$EUID" -ne 0 ]; then
        log_error "Этот скрипт должен быть запущен от имени root. Используйте 'sudo'."
        exit 1
    fi
    log_info "Права суперпользователя подтверждены."
}

# Установка зависимостей (Git, Docker)
install_dependencies() {
    log_info "Проверка и установка зависимостей..."
    
    # Обновляем список пакетов один раз
    log_info "Обновление списка пакетов..."
    apt-get update >/dev/null

    # Установка Git
    if command -v git &>/dev/null; then
        log_info "Git уже установлен."
    else
        log_info "Git не найден. Установка..."
        apt-get install -y git
        log_info "Git успешно установлен."
    fi

    # Установка Docker
    if command -v docker &>/dev/null; then
        log_info "Docker уже установлен."
    else
        log_info "Docker не найден. Установка..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        log_info "Docker успешно установлен."
    fi

    # Установка Docker Compose
    if docker compose version &>/dev/null; then
        log_info "Docker Compose уже установлен."
    else
        log_info "Docker Compose не найден. Установка плагина..."
        apt-get install -y docker-compose-plugin
        log_info "Плагин Docker Compose успешно установлен."
    fi
}

# Клонирование репозитория и запуск установки
clone_and_install() {
    log_info "Клонирование репозитория в ${INSTALL_DIR}..."

    if [ -d "${INSTALL_DIR}" ]; then
        log_warn "Директория ${INSTALL_DIR} уже существует. Удаление для свежей установки..."
        rm -rf "${INSTALL_DIR}"
    fi
    
    git clone "${REPO_URL}" "${INSTALL_DIR}"
    cd "${INSTALL_DIR}"
    
    log_info "Репозиторий успешно склонирован. Запуск скриптов установки..."
    
    log_info "Генерация .env файла..."
    ./envgen.sh
    
    log_info "Развертывание Docker-стека..."
    ./deploy.sh
}

# --- Основное выполнение ---
main() {
    check_root
    install_dependencies
    clone_and_install
    log_info "Bootstrap-скрипт и установка успешно завершены!"
    log_info "Проект развернут в директории ${INSTALL_DIR}"
}

# Запуск основной функции
main


