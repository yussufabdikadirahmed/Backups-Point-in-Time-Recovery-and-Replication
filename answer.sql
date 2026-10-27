#!/bin/bash
# ===== STEP 1: Logical backup & verify =====
mkdir -p ~/backups
pg_dump -Fc -f ~/backups/bootcamp.dump bootcamp
pg_restore --list ~/backups/bootcamp.dump | head
createdb bootcamp_check
pg_restore -d bootcamp_check ~/backups/bootcamp.dump

# ===== STEP 2: WAL archiving + base backup =====
mkdir -p ~/backups/wal

# Manually edit postgresql.conf first, adding:
#   wal_level = replica
#   archive_mode = on
#   archive_command = 'cp %p /home/'"$USER"'/backups/wal/%f'
# (replace $USER with your literal username inside the file - postgresql.conf does not expand shell vars)

sudo systemctl restart postgresql
pg_basebackup -D ~/backups/base -Ft -z -Xs -P

# ===== STEP 3: Simulate disaster (run in psql) =====
psql -d bootcamp -c "SELECT now();"          # record this timestamp!
psql -d bootcamp -c "DELETE FROM students;"  # oops

# --- Recovery (manual, after noting the timestamp above) ---
sudo systemctl stop postgresql
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main.bak
sudo mkdir /var/lib/postgresql/16/main
sudo tar -xzf ~/backups/base/base.tar.gz -C /var/lib/postgresql/16/main
sudo chown -R postgres:postgres /var/lib/postgresql/16/main

# Manually edit postgresql.conf, adding:
#   restore_command = 'cp /home/'"$USER"'/backups/wal/%f %p'
#   recovery_target_time = 'PASTE_THE_TIMESTAMP_YOU_RECORDED'

sudo -u postgres touch /var/lib/postgresql/16/main/standby.signal
sudo systemctl start postgresql
psql -d bootcamp -c "SELECT count(*) FROM students;"   # verify recovery
psql -d bootcamp -c "SELECT pg_promote();"              # exit recovery mode

# ===== STEP 4: Streaming standby =====
psql -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'reppass';"

# Manually add to pg_hba.conf:
#   host replication replicator 127.0.0.1/32 md5

sudo systemctl reload postgresql
pg_basebackup -h 127.0.0.1 -U replicator -D ~/standby -R -P
pg_ctl -D ~/standby -o "-p 5433" start

# ===== STEP 5: Watch replication health =====
psql -c "SELECT application_name, state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes FROM pg_stat_replication;"
psql -h 127.0.0.1 -p 5433 -c "SELECT pg_is_in_recovery();"
