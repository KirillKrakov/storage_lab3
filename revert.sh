#!/bin/bash

# Корректные пути для вашей системы
export PGDATA=/var/db/postgres0/evh98
BACKUP_DIR="backups"
REMOTE_HOST="postgres2@pg111"
CONFIG_DIR="configs"  # Директория с резервными конфигами
NEW_TS_DIR="/var/db/postgres0/new_fnd85"  # Новый путь для табличного пространства

# 1. Остановка СУБД (если запущена)
echo "Останавливаем PostgreSQL..."
pg_ctl -D $PGDATA stop >/dev/null 2>&1 || echo "Предупреждение: не удалось остановить сервер (возможно уже остановлен)"

# 2. Восстановление конфигурации
echo "Восстанавливаем конфигурационные файлы..."
scp $REMOTE_HOST:"$CONFIG_DIR/postgresql.conf" $PGDATA/
scp $REMOTE_HOST:"$CONFIG_DIR/pg_hba.conf" $PGDATA/

# 3. Работа с табличным пространством
echo "Обработка табличного пространства fnd85..."
TS_OID=$(psql -d postgres -p 9792 -Atc "SELECT oid FROM pg_tablespace WHERE spcname = 'fnd85';" 2>/dev/null)

if [ -n "$TS_OID" ]; then
    echo "Переносим табличное пространство в $NEW_TS_DIR"
    mkdir -p $NEW_TS_DIR
    chmod 750 $NEW_TS_DIR
    chown postgres0:postgres0 $NEW_TS_DIR

    # Копирование бэкапа табличного пространства
    latest_backup=$(ssh $REMOTE_HOST "ls -t ${BACKUP_DIR}/backup_all_* | head -n 1")
    scp $REMOTE_HOST:"$latest_backup" /var/db/postgres0/tmp_backup.tar.gz
    tar -xzf /var/db/postgres0/tmp_backup.tar.gz -C $NEW_TS_DIR
    
    # Обновление ссылки
    cd $PGDATA/pg_tblspc
    rm -f $TS_OID
    ln -s $NEW_TS_DIR $TS_OID
else
    echo "Табличное пространство fnd85 не найдено, пропускаем"
fi

# 4. Запуск СУБД
echo "Запускаем PostgreSQL..."
pg_ctl -D $PGDATA start

# 5. Восстановление данных (если нужно)
if [ -n "$TS_OID" ] && [ -f "/var/db/postgres0/tmp_backup.tar.gz" ]; then
    echo "Восстанавливаем данные из бэкапа"
    gunzip -c /var/db/postgres0/tmp_backup.tar.gz > /var/db/postgres0/tmp_backup.sql
    psql -d postgres -p 9792 -f /var/db/postgres0/tmp_backup.sql
    rm -f /var/db/postgres0/tmp_backup.*
fi

echo "Восстановление завершено!"