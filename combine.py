#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Собирает содержимое ключевых файлов IoT-стека в один Markdown.
Запускать из папки iot-stack.
- Добавляет метаданные (размер, дата изменения, кодировка)
- Корректно обрабатывает пустые файлы и директории
- Безопасно декодирует (utf-8 -> cp1251 -> latin-1), не падает на бинарных
- Для директорий рекурсивно включает файлы (например, .influxdb-config)
"""

import os
import sys
import codecs
from datetime import datetime

# Целевые пути (файлы и/или директории)
TARGETS = [
    ".env",
    "docker-compose.yml",
    "telegraf/telegraf.conf",
    "api/main.py",
    "api/Dockerfile",
    ".mosquitto/config/mosquitto.conf",
    ".mosquitto/config/passwd",
    ".influxdb-config/influx-configs",
]

OUTPUT = "combined_files.md"

LANG_MAP = {
    ".py": "python",
    ".yml": "yaml",
    ".yaml": "yaml",
    ".conf": "ini",
    ".env": "ini",
}

# Имя-фильтры по содержимому пути
NAME_LANG_HINTS = [
    ("Dockerfile", "dockerfile"),
]

SKIP_DIRS = {".git", "__pycache__"}


def guess_lang(path: str) -> str:
    base = os.path.basename(path)
    for hint, lang in NAME_LANG_HINTS:
        if hint in base:
            return lang
    _, ext = os.path.splitext(base)
    return LANG_MAP.get(ext.lower(), "plaintext")


def choose_fence(content: str) -> str:
    # Если в содержимом есть ``` – используем 4 обратные кавычки
    return "````" if "```" in content else "```"


def decode_bytes(data: bytes) -> tuple[str, str]:
    for enc in ("utf-8", "cp1251", "latin-1"):
        try:
            return data.decode(enc), enc
        except UnicodeDecodeError:
            continue
    # Последняя попытка – безопасная замена
    return data.decode("utf-8", errors="replace"), "utf-8+replace"


def iter_targets() -> list[str]:
    paths: list[str] = []
    for t in TARGETS:
        if os.path.isdir(t):
            for root, dirs, files in os.walk(t):
                # Пропуск системных директорий
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
                for fn in files:
                    paths.append(os.path.join(root, fn))
        else:
            paths.append(t)
    # Убираем дубликаты и сортируем для стабильности
    uniq = sorted(dict.fromkeys(paths))
    return uniq


def format_file_section(path: str) -> str:
    if not os.path.exists(path):
        return f"## Файл: {path}\n\n_Файл не найден_\n\n"
    if os.path.isdir(path):
        return f"## Путь: {path}\n\n_Это директория; файлы из неё включены отдельно_\n\n"

    try:
        size = os.path.getsize(path)
        mtime = datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d %H:%M:%S")
        with open(path, "rb") as f:
            raw = f.read()
        text, used_enc = decode_bytes(raw)
    except Exception as e:
        return f"## Файл: {path}\n\n_Ошибка чтения: {e}_\n\n"

    lang = guess_lang(path)
    fence = choose_fence(text)
    meta = f"- Размер: {size} байт; Изменён: {mtime}; Кодировка: {used_enc}\n"

    # Помечаем реально пустые файлы
    if size == 0 or text.strip() == "":
        body = f"{meta}\n_Файл пуст или содержит только пробельные символы_\n\n"
        return f"## Файл: {path}\n\n{body}"

    return f"## Файл: {path}\n\n{meta}{fence}{lang}\n{text}\n{fence}\n\n"


def main() -> int:
    parts: list[str] = []
    for p in iter_targets():
        parts.append(format_file_section(p))

    with open(OUTPUT, "w", encoding="utf-8") as out:
        out.write("".join(parts))

    print(f"Готово: {OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
