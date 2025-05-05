# Этап 1. Резервное копирование

## Генерация SSH-ключа для автоматической авторизации scp на основном узле
Сгенерируем SSH-ключ для автоматической авторизации scp на основном узле:
```sh
eval $(ssh-agent -s)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa
ssh-add ~/.ssh/id_rsa
ssh-copy-id postgres2@pg111
```

Сразу же проверим доступ (на основном узле):
```sh
ssh postgres2@pg111
```

##  Настройка полного резервного копирования (pg_dump) по расписанию
Создаем директории для хранения резервных копий на резервном узле:
```sh
mkdir $HOME/backups
```

На основном узле редактируем pg_hba.conf - добавим разрешение подключения для репликации:
```sh
local   replication     all                     peer
```

Создадим скрипт backup.sh для резервного копипрования на основном узле:
```sh
#!/bin/sh
CURRENT_DATE=$(date "+%Y-%m-%d_%H:%M:%S")
BACKUP_DIR="backups"
ARCHIVE_NAME="backup_all_${CURRENT_DATE}.tar.gz"
REMOTE_HOST="postgres2@pg111"
# Создаем полную резервную копию, размещенную на резервном узле в виде архива
ssh ${REMOTE_HOST} "mkdir ${BACKUP_DIR}"
pg_dumpall -p 9792 |  gzip | ssh ${REMOTE_HOST} "cat > ${BACKUP_DIR}/${ARCHIVE_NAME}"
# Удаляем резервные копии старше 28 дней на резервном узле
ssh ${REMOTE_HOST} 'find backups/ -type d -mtime +28 -exec rm -rf {} \;'
```

Загрузим скрипт в корень на основном узле и сделаем его исполняемым:
```sh
chmod +x backup.sh
```

Запускаем сервер и проверяем работоспособность скрипта:
```sh
pg_ctl -D $HOME/evh98 -l $HOME/evh98/logfile start
bash $HOME/backup.sh >> $HOME/backup.log 2>&1
cat backup.log
```

Добавляем задачу в cron на основном узле:
```sh
crontab -e
```

Добавляем строчку (в 1 минуту, в 0 часов, в любой день месяца, в любой месяц, в любой день недели):
```sh
1 0 * * * $HOME/backup.sh >> $HOME/backup.log 2>&1
```

## Расчет объема резервных копий
Подсчитать, каков будет объем резервных копий спустя месяц работы системы, исходя из следующих условий:
Будем считать, что месяц = 4 недели.
* Средний объем новых данных в БД за сутки: 200МБ.
* Средний объем измененных данных за сутки: 750МБ.
* Частота полного резервного копирования: раз в сутки (посредством pg_dump со сжатием). В среднем сжатие уменьшает размер на 50-70%. Примем за средние 60%.
* Срок хранения копий:
    * На резервном узле: 4 недели.

__Подсчет:__

Объем данных за неделю:
* Новых: 200 МБ * 7 = 1.4 ГБ
* Измененных: 750 МБ * 7 = 5.25 ГБ

Объем резервных копий на основном узле за месяц:
* Итого: 0 ГБ

Объем резервных копий на резервном узле:
* Полных:
    * Копии хранятся 4 недели, так что будут 4 копии с данными за 1, 2, 3 и 4 недели.
    * 1 * 1.4 ГБ + 2 * 1.4 ГБ + 3 * 1.4 ГБ + 4 * 1.4 ГБ = 14 ГБ
    * Суммарный объем: 14 ГБ * 40% = 5.6 ГБ
* Итого: 5.6 ГБ


# Этап 2. Потеря основного узла
Скопируем pg_hba.conf и postgresql.conf на резервный узел без изменений. Поместим данные файлы в директорию configs:
```sh
mkdir $HOME/configs (на резервном узле)
scp $HOME/evh98/postgresql.conf $HOME/evh98/pg_hba.conf postgres2@pg111:/var/db/postgres2/configs (на основном узле)
```

Напишем скрипт для восстановления базы данных restore.sh на резервном узле:
```sh
#!/bin/bash

export PGDATA=$HOME/evh98 
export ENC=ISO8859-15 
export LOC=en_US.ISO8859-15
BACKUP_DIR="$HOME/backups"
DB_DIR="$HOME/evh98"
CONFIG_DIR="$HOME/configs"
TEMP_DIR="$HOME/backups/tmp.sql"
tablespaces=(
    ["tablespace1"]="$HOME/fnd85"
)
latest_backup=$(ls -t ${BACKUP_DIR}/backup_all_* | head -n 1)
# Находим самый поздний backup
if [ ! -f "${latest_backup}" ]; then 
    echo "No backup files found" 
    exit 1
fi
echo "Using ${latest_backup}"
# Останавливаем сервер
pg_ctl -D ${DB_DIR} stop
# Пересоздаем директории кластера 
rm -rf ${DB_DIR}
mkdir ${DB_DIR}
for ts in "${!tablespaces[@]}"; do 
    dir="${tablespaces[$ts]}"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
    else 
        rm -rf "$dir"
        mkdir -p "$dir"
    fi
done
ls -la $PGDATA
initdb -D $PGDATA --encoding=$ENC --locale=$LOC
cp ${CONFIG_DIR}/postgresql.conf ${DB_DIR}/postgresql.conf
cp ${CONFIG_DIR}/pg_hba.conf ${DB_DIR}/pg_hba.conf
gunzip -c "${latest_backup}" > "$TEMP_DIR"
pg_ctl -D ${DB_DIR} start
# Восстанавливаем данные из дампа 
psql -d postgres -p 9792 -f $TEMP_DIR
rm -rf "$TEMP_DIR"
echo "Complete"
```

Сделаем файл restore.sh исполняемым:
```sh
chmod +x $HOME/restore.sh
```

Проверим работу скрипта для восстановления restore.sh
```sh
bash $HOME/restore.sh
```

# Этап 3. Повреждение файлов БД

Для проверки создадим таблицу fnd85_test_table в табличном пространстве fnd85:
```SQL
psql -p 9792 -d drypinklab
CREATE TABLE fnd85_test_table (id SERIAL PRIMARY KEY, data TEXT
) TABLESPACE fnd85;
INSERT INTO fnd85_test_table (data) VALUES ('test 1');
```

Проверим доступность записанных данных:
```SQL
SELECT * FROM fnd85_test_table;
```
```
 id |  data
----+--------
  1 | test 1
(1 строка)
```

Сделаем бэкап:
```sh
bash $HOME/backup.sh >> $HOME/backup.log 2>&1
```

Удалим конфигурационныt файлы СУБД со всем содержимым (симуляция сбоя):
```sh
rm -rf $HOME/evh98/postgresql.conf $HOME/evh98/pg_hba.conf
```

Если попробовать снова получить данные из таблицы fnd85_test_table, то всё пройдёт успешно:
```sh
psql -p 9792 -d drypinklab -c "SELECT * FROM fnd85_test_table;"
```
```
 id |  data
----+--------
  1 | test 1
(1 строка)
```

А теперь попробуем перезапустить СУБД:
```sh
pg_ctl -D $HOME/evh98 restart
```

Ожидаемо получаем ошибку:
```
ожидание завершения работы сервера.... готово
сервер остановлен
ожидание запуска сервера....postgres не может открыть файл конфигурации сервера "/var/db/postgres0/evh98/postgresql.conf": No such file or directory
 прекращение ожидания
pg_ctl: не удалось запустить сервер
Изучите протокол выполнения.
```

Снова попробуем получить ранее записанные данные в таблицу fnd85_test_table:
```sh
psql -p 9792 -d drypinklab -c "SELECT * FROM fnd85_test_table;"
```
Ожидаемо получаем ошибку из-за того, что не удалось подключиться к серверу (он не работает):
```
psql: ошибка: подключиться к серверу "127.0.0.1", порту 9792 не удалось: Connection refused
Сервер действительно работает по данному адресу и принимает TCP-соединения?
```

Напишем скрипт revert.sh , который с помощью последнего бэкапа восстановит fnd85 в новом месте:
```sh
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
```

Загрузим и сделаем исполняемым:
```sh
chmod +x revert.sh
```

Выполним загруженный скрипт:
```sh
bash $HOME/revert.sh
```

Проверим доступность данных в таблице fnd85_test_table:
```SQL
psql -p 9792 -d drypinklab
SELECT * FROM fnd85_test_table;
```

Видим, что данные снова доступны:
```
 id |  data
----+--------
  1 | test 1
(1 строка)
```

# Этап 4. Логическое повреждение данных

Создадим директорию для архивирования и восстановления WAL-файлов:
```sh
mkdir wal_archive
chmod 700 wal_archive
```

Включим WAL в postgresql.conf:
```sh
wal_level = replica
archive_command = 'cp %p $HOME/wal_archive/%f'
restore_command = 'cp $HOME/wal_archive/%f %p'
```

Создадим таблицы с внешними ключами:
```SQL
psql -p 9792 -d postgres

-- Таблица с первичным ключом
CREATE TABLE parent_table (
    id SERIAL PRIMARY KEY,
    data TEXT
);

-- Таблица с внешним ключом
CREATE TABLE child_table (
    parent_id INTEGER REFERENCES parent_table(id) ON DELETE CASCADE,
    details TEXT
);

-- Вставляем данные
INSERT INTO parent_table (data) VALUES 
    ('Parent 1'),
    ('Parent 2'),
    ('Parent 3');

INSERT INTO child_table (parent_id, details) VALUES
    (1, 'Child 1'),
    (2, 'Child 2'),
    (3, 'Child 3');

-- Проверяем данные
SELECT * FROM parent_table;
 id |   data
----+----------
  1 | Parent 1
  2 | Parent 2
  3 | Parent 3
(3 строки)

SELECT * FROM child_table;
 parent_id | details
-----------+---------
         1 | Child 1
         2 | Child 2
         3 | Child 3
(3 строки)
```
Сделаем бэкап:
```sh
pg_basebackup -D RESERVE -X stream -p 9792
```
Запоминаем время:
```sh
psql -p 9792 -d postgres -c "SELECT now();"
```
```
              now
-------------------------------
 2025-05-05 06:39:18.238291+03
```
Испортим данные во второй таблице child_table:
```SQL
ALTER TABLE child_table DROP CONSTRAINT child_table_parent_id_fkey;

-- Меняем значения внешнего ключа
UPDATE child_table SET parent_id = 10 WHERE parent_id = 1;
UPDATE child_table SET parent_id = 20 WHERE parent_id = 2;
UPDATE child_table SET parent_id = 30 WHERE parent_id = 3;

ALTER TABLE child_table 
    ADD CONSTRAINT child_table_parent_id_fkey 
    FOREIGN KEY (parent_id) REFERENCES parent_table(id) 
    NOT VALID;
```

Проверим содержимое таблиц:
```SQL
SELECT * FROM parent_table;
 id |   data
----+----------
  1 | Parent 1
  2 | Parent 2
  3 | Parent 3
(3 строки)
```

```SQL
SELECT * FROM child_table;
 parent_id | details
-----------+---------
        10 | Child 1
        20 | Child 2
        30 | Child 3
(3 строки)
```
Остановим сервер:
```sh
pg_ctl -D $HOME/evh98 stop
```
Вернем данные на момент бэкапа:
```sh
rm -rf evh98
cp -r RESERVE/ evh98/
```
Изменим postgresql.conf:
```sh
recovery_target_time = '2025-05-05 06:39:18'
recovery_target_action = 'promote'
```
Создадим файл внутри директории кластера, он сообщит БД, что нужно восстановить данные из архива:
```sh
touch evh98/recovery.signal
chmod -R 750 evh98
```
Запустим сервер, дождемся восстановления: 
```sh
pg_ctl -D evh98 start
rm evh98/recovery.signal
pg_ctl -D evh98 start
``` 
Проверим состояние таблицы:
```sh
SELECT * FROM child_table;
 parent_id | details
-----------+---------
         1 | Child 1
         2 | Child 2
         3 | Child 3
(3 строки)
```