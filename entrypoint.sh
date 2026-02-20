#!/bin/sh

# Set the timezone. Base image does not contain the setup-timezone script, so an alternate way is used.
if [ "$CONTAINER_TIMEZONE" ]; then
    cp /usr/share/zoneinfo/${CONTAINER_TIMEZONE} /etc/localtime && \
    echo "${CONTAINER_TIMEZONE}" > /etc/timezone && \
    echo "Container timezone set to: $CONTAINER_TIMEZONE"
fi

# Force immediate synchronisation of the time and start the time-synchronization service.
ntpd -s

# Apache server name change
if [ ! -z "$APACHE_SERVER_NAME" ]; then
    sed -i "s/#ServerName www.example.com:80/ServerName $APACHE_SERVER_NAME/" /etc/apache2/httpd.conf
    echo "Changed server name to '$APACHE_SERVER_NAME'..."
fi

# -------------------------------------------------------------------
# Configure PHP application DB credentials from environment variables
# -------------------------------------------------------------------
DB_CREDS_FILE="/app/public/sql-connections/db-creds.inc"
if [ -f "$DB_CREDS_FILE" ] && [ -n "$DB_HOST" ]; then
    echo "Configuring database credentials from environment..."
    cat > "$DB_CREDS_FILE" <<PHPCREDS
<?php
\$dbuser = '${DB_USER:-root}';
\$dbpass = '${DB_PASS}';
\$dbname = '${DB_NAME:-security}';
\$host   = '${DB_HOST}';
\$dbname1 = 'challenges';
?>
PHPCREDS
    echo "Database credentials configured (host=$DB_HOST, user=${DB_USER:-root})."
fi

# -------------------------------------------------------------------
# Wait for MariaDB and initialize the database
# -------------------------------------------------------------------
if [ -n "$DB_HOST" ]; then
    # Docker healthcheck should guarantee MariaDB is ready, but do a quick sanity check
    echo "Verifying MariaDB connectivity at $DB_HOST..."
    RETRY=0
    until mysql -h "$DB_HOST" -u "${DB_USER:-root}" -p"${DB_PASS}" -e "SELECT 1" > /dev/null 2>&1; do
        RETRY=$((RETRY + 1))
        if [ "$RETRY" -ge 5 ]; then
            echo "ERROR: MariaDB not reachable after $RETRY attempts. Continuing without DB init."
            break
        fi
        echo "  Waiting for MariaDB (attempt $RETRY/5)..."
        sleep 2
    done

    if [ "$RETRY" -lt 5 ]; then
        echo "MariaDB is ready. Running database initialization scripts..."

        # Run the main application SQL (creates 'security' DB with tables and data)
        if [ -f /app/public/sql-lab.sql ]; then
            mysql -h "$DB_HOST" -u "${DB_USER:-root}" -p"${DB_PASS}" < /app/public/sql-lab.sql \
                && echo "  -> sql-lab.sql applied." \
                || echo "  -> sql-lab.sql failed (may already exist)."
        fi

        # Run any scripts placed in /docker-entrypoint-initdb.d/
        for f in /docker-entrypoint-initdb.d/*.sql; do
            if [ -f "$f" ]; then
                mysql -h "$DB_HOST" -u "${DB_USER:-root}" -p"${DB_PASS}" < "$f" \
                    && echo "  -> $(basename $f) applied." \
                    || echo "  -> $(basename $f) failed (may already exist)."
            fi
        done

        echo "Database initialization complete."
    fi
fi

# -------------------------------------------------------------------
# Start Apache
# -------------------------------------------------------------------
echo "Clearing any old processes..."
rm -f /run/apache2/apache2.pid
rm -f /run/apache2/httpd.pid

echo "Starting apache..."
httpd -D FOREGROUND
