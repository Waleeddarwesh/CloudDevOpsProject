sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-sonarqube.conf

mkdir -p /opt/sonarqube/data /opt/sonarqube/extensions /opt/sonarqube/logs /opt/sonarqube/postgresql
chown -R 1000:1000 /opt/sonarqube/data /opt/sonarqube/extensions /opt/sonarqube/logs
chown -R 999:999 /opt/sonarqube/postgresql
chmod 0700 /opt/sonarqube/postgresql

cat << 'EOF' > /opt/sonarqube/docker-compose.yml
name: sonarqube
services:
  db:
    image: postgres:15-alpine
    container_name: sonarqube-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: \
      POSTGRES_DB: sonarqube
    volumes:
      - /opt/sonarqube/postgresql:/var/lib/postgresql/data
    networks:
      - sonarnet
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sonar -d sonarqube"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  sonarqube:
    image: sonarqube:lts-community
    container_name: sonarqube
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://db:5432/sonarqube
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: \
      SONAR_WEB_JAVAOPTS: "-Xmx512m -Xms256m"
      SONAR_CE_JAVAOPTS: "-Xmx512m -Xms256m"
      SONAR_SEARCH_JAVAOPTS: "-Xmx512m -Xms256m"
    volumes:
      - /opt/sonarqube/data:/opt/sonarqube/data
      - /opt/sonarqube/extensions:/opt/sonarqube/extensions
      - /opt/sonarqube/logs:/opt/sonarqube/logs
    networks:
      - sonarnet
    ports:
      - "9000:9000"
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
      nproc: 8192
    healthcheck:
      test:
        - CMD-SHELL
        - wget --no-verbose --tries=1 --spider http://localhost:9000/api/system/status || exit 1
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 180s

networks:
  sonarnet:
    driver: bridge
EOF

cat << 'EOF' > /opt/sonarqube/.env
SONARQUBE_DB_PASSWORD=SuperSecretDBPass2026!
EOF

cd /opt/sonarqube
docker compose up -d
