function devTools() {
  
  LATEST=false
  PI_WORK_DIR=${OKD_LAB_PATH}/work-dir-pi
  rm -rf ${PI_WORK_DIR}
  mkdir -p ${PI_WORK_DIR}
  for i in "$@"
  do
    case ${i} in
      # -p)
      #   installPostgreSQL
      # ;;
      -n)
        instalNexus
      ;;
      -g)
        installGitea
      ;;
      -k)
        installKeyCloak
      ;;
      -a)
        installApicurio
      ;;
      --all)
        # installPostgreSQL
        instalNexus
        installGitea
        installKeyCloak
        installApicurio
      ;;
      --latest)
        LATEST=true
      ;;
      *)
        # catch all
      ;;
    esac
  done
}

function instalNexus() {

cat <<EOF > ${PI_WORK_DIR}/nexus
#!/bin/sh /etc/rc.common

START=99
STOP=80
SERVICE_USE_PID=0

start() {
   ulimit -Hn 65536
   ulimit -Sn 65536
    service_start /usr/local/nexus/nexus-3/bin/nexus start
}

stop() {
    service_stop /usr/local/nexus/nexus-3/bin/nexus stop
}
EOF

cat <<EOF > ${PI_WORK_DIR}/nexus.properties
nexus-args=\${jetty.etc}/jetty.xml,\${jetty.etc}/jetty-https.xml,\${jetty.etc}/jetty-requestlog.xml
application-port-ssl=8443
EOF

  ${SSH} root@${BASTION_HOST} "mkdir -p /usr/local/nexus/home ; \
    cd /usr/local/nexus ; \
    wget https://download.sonatype.com/nexus/3/latest-unix.tar.gz -O latest-unix.tar.gz ; \
    tar -xzf latest-unix.tar.gz ; \
    NEXUS=\$(ls -d nexus-*) ; \
    ln -s \${NEXUS} nexus-3 ; \
    rm -f latest-unix.tar.gz ; \
    groupadd nexus ; \
    useradd -g nexus -d /usr/local/nexus/home nexus ; \
    chown -R nexus:nexus /usr/local/nexus"
  ${SSH} root@${BASTION_HOST} 'sed -i "s|#run_as_user=\"\"|run_as_user=\"nexus\"|g" /usr/local/nexus/nexus-3/bin/nexus.rc'
  
  ${SCP} ${PI_WORK_DIR}/nexus root@${BASTION_HOST}:/etc/init.d/nexus
  ${SSH} root@${BASTION_HOST} "chmod 755 /etc/init.d/nexus"

  ${SSH} root@${BASTION_HOST} 'sed -i "s|# INSTALL4J_JAVA_HOME_OVERRIDE=|INSTALL4J_JAVA_HOME_OVERRIDE=/usr/local/java-1.8-openjdk|g" /usr/local/nexus/nexus-3/bin/nexus'

  ${SSH} root@${BASTION_HOST} "/usr/local/java-1.8-openjdk/bin/keytool -genkeypair -keystore /usr/local/nexus/nexus-3/etc/ssl/keystore.jks -deststoretype pkcs12 -storepass password -keypass password -alias jetty -keyalg RSA -keysize 4096 -validity 5000 -dname \"CN=nexus.${LAB_DOMAIN}, OU=okd4-lab, O=okd4-lab, L=City, ST=State, C=US\" -ext \"SAN=DNS:nexus.${LAB_DOMAIN},IP:${BASTION_HOST}\" -ext \"BC=ca:true\" ; \
    /usr/local/java-1.8-openjdk/bin/keytool -importkeystore -srckeystore /usr/local/nexus/nexus-3/etc/ssl/keystore.jks -destkeystore /usr/local/nexus/nexus-3/etc/ssl/keystore.jks -deststoretype pkcs12 -srcstorepass password  ; \
    rm -f /usr/local/nexus/nexus-3/etc/ssl/keystore.jks.old  ; \
    chown nexus:nexus /usr/local/nexus/nexus-3/etc/ssl/keystore.jks  ; \
    mkdir -p /usr/local/nexus/sonatype-work/nexus3/etc"
  cat ${PI_WORK_DIR}/nexus.properties | ${SSH} root@${BASTION_HOST} "cat >> /usr/local/nexus/sonatype-work/nexus3/etc/nexus.properties"
  ${SSH} root@${BASTION_HOST} "chown -R nexus:nexus /usr/local/nexus/sonatype-work/nexus3/etc ; /etc/init.d/nexus enable"
  echo "nexus.${LAB_DOMAIN}.           IN      A      ${BASTION_HOST}" | ${SSH} root@${EDGE_ROUTER} "cat >> /data/bind/db.${LAB_DOMAIN}"
  ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
}

function installGitea() {

  # wget -O /usr/local/gitea/bin/gitea https://dl.gitea.io/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-arm64
  if [[ ${LATEST} == "true" ]]
  then
    GITEA_VERSION=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/go-gitea/gitea/releases/latest) | cut -d'v' -f2)
    yq e ".gitea-version = \"${GITEA_VERSION}\"" -i ${LAB_CONFIG_FILE}
  fi
  GITEA_VERSION=$(yq e ".gitea-version" ${LAB_CONFIG_FILE})
  ${SSH} root@${BASTION_HOST} "opkg update && opkg install sqlite3-cli openssh-keygen ; \
    mkdir -p /usr/local/gitea ; \
    for i in bin etc custom data db git ; \
    do mkdir /usr/local/gitea/\${i} ; \
    done ; \
    wget -O /usr/local/gitea/bin/gitea https://github.com/go-gitea/gitea/releases/download/v${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-arm64 ; \
    chmod 750 /usr/local/gitea/bin/gitea ; \
    cd /usr/local/gitea/custom ; \
    /usr/local/gitea/bin/gitea cert --host gitea.${LAB_DOMAIN} ; \
    groupadd gitea ; \
    useradd -g gitea -d /usr/local/gitea gitea ; \
    chown -R gitea:gitea /usr/local/gitea"
  INTERNAL_TOKEN=$(${SSH} root@${BASTION_HOST} "/usr/local/gitea/bin/gitea generate secret INTERNAL_TOKEN")
  SECRET_KEY=$(${SSH} root@${BASTION_HOST} "/usr/local/gitea/bin/gitea generate secret SECRET_KEY")
  JWT_SECRET=$(${SSH} root@${BASTION_HOST} "/usr/local/gitea/bin/gitea generate secret JWT_SECRET")

cat << EOF > ${PI_WORK_DIR}/app.ini
RUN_USER = gitea
RUN_MODE = prod

[repository]
ROOT = /usr/local/gitea/git
SCRIPT_TYPE = sh
DEFAULT_BRANCH = main
DEFAULT_PUSH_CREATE_PRIVATE = true
ENABLE_PUSH_CREATE_USER = true
ENABLE_PUSH_CREATE_ORG = true

[server]
PROTOCOL = https
ROOT_URL = https://gitea.${LAB_DOMAIN}:3000/
HTTP_PORT = 3000
CERT_FILE = cert.pem
KEY_FILE  = key.pem
STATIC_ROOT_PATH = /usr/local/gitea/web
APP_DATA_PATH    = /usr/local/gitea/data
LFS_START_SERVER = true

[service]
DISABLE_REGISTRATION = true

[database]
DB_TYPE = sqlite3
PATH = /usr/local/gitea/db/gitea.db

[security]
INSTALL_LOCK = true
SECRET_KEY = ${SECRET_KEY}
INTERNAL_TOKEN = ${INTERNAL_TOKEN}

[oauth2]
JWT_SECRET = ${JWT_SECRET}

[session]
PROVIDER = file

[log]
ROOT_PATH = /usr/local/gitea/log
MODE = file
LEVEL = Info

[webhook]
ALLOWED_HOST_LIST = *
EOF

cat <<EOF > ${PI_WORK_DIR}/gitea
#!/bin/sh /etc/rc.common

START=99
STOP=80
SERVICE_USE_PID=0

start() {
   service_start /usr/bin/su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/bin/nohup /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini web > /dev/null 2>&1 &'
}

restart() {
   /usr/bin/su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini manager restart'
}

stop() {
   /usr/bin/su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini manager shutdown'
}
EOF

cat <<EOF > ${PI_WORK_DIR}/giteaInit.sh
su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini migrate'
su - gitea -c "GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini admin user create --admin --username gitea --password password --email gitea@gitea.${LAB_DOMAIN} --must-change-password"
su - gitea -c "GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini admin user create --username devuser --password password --email devuser@gitea.${LAB_DOMAIN} --must-change-password"
EOF

  ${SCP} ${PI_WORK_DIR}/app.ini root@${BASTION_HOST}:/usr/local/gitea/etc/app.ini
  ${SCP} ${PI_WORK_DIR}/gitea root@${BASTION_HOST}:/etc/init.d/gitea
  ${SCP} ${PI_WORK_DIR}/giteaInit.sh root@${BASTION_HOST}:/tmp/giteaInit.sh
  ${SSH} root@${BASTION_HOST} "chown -R gitea:gitea /usr/local/gitea ; chmod 755 /etc/init.d/gitea ; chmod 755 /tmp/giteaInit.sh ; /tmp/giteaInit.sh ; /etc/init.d/gitea enable"
  echo "gitea.${LAB_DOMAIN}.           IN      A      ${BASTION_HOST}" | ${SSH} root@${EDGE_ROUTER} "cat >> /data/bind/db.${LAB_DOMAIN}"
  ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
}

function installKeyCloak() {

  if [[ ${LATEST} == "true" ]]
  then
    KEYCLOAK_VER=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/keycloak/keycloak/releases/latest))
    yq e ".keycloak-version = \"${KEYCLOAK_VER}\"" -i ${LAB_CONFIG_FILE}
  fi
  KEYCLOAK_VER=$(yq e ".keycloak-version" ${LAB_CONFIG_FILE})

cat << EOF > ${PI_WORK_DIR}/keycloak.conf
hostname=keycloak.${LAB_DOMAIN}
http-enabled=false
https-key-store-file=/usr/local/keycloak/keystore.jks
https-port=7443
EOF

cat <<EOF > ${PI_WORK_DIR}/keycloak
#!/bin/sh /etc/rc.common

START=99
STOP=80
SERVICE_USE_PID=0

start() {
   service_start /usr/bin/su - keycloak -c 'PATH=/usr/local/java-11-openjdk/bin:\${PATH} /usr/local/keycloak/keycloak-server/bin/kc.sh start > /dev/null 2>&1 &'
}

restart() {
   /usr/bin/su - keycloak -c 'kill \$(ps -x | grep keycloak | grep java | cut -d" " -f2)'
   service_start /usr/bin/su - keycloak -c 'PATH=/usr/local/java-11-openjdk/bin:\${PATH} /usr/local/keycloak/keycloak-server/bin/kc.sh start > /dev/null 2>&1 &'
}

stop() {
   /usr/bin/su - keycloak -c 'kill \$(ps -x | grep keycloak | grep java | cut -d" " -f2)'
}
EOF

  ${SSH} root@${BASTION_HOST} "mkdir -p /usr/local/keycloak ; \
    cd /usr/local/keycloak ; \
    wget -O keycloak-${KEYCLOAK_VER}.zip https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VER}/keycloak-${KEYCLOAK_VER}.zip ; \
    unzip keycloak-${KEYCLOAK_VER}.zip ; \
    ln -s keycloak-${KEYCLOAK_VER} keycloak-server ; \
    /usr/local/java-11-openjdk/bin/keytool -genkeypair -keystore /usr/local/keycloak/keystore.jks -deststoretype pkcs12 -storepass password -keypass password -alias jetty -keyalg RSA -keysize 4096 -validity 5000 -dname \"CN=keycloak.${LAB_DOMAIN}, OU=okd4-lab, O=okd4-lab, L=City, ST=State, C=US\" -ext \"SAN=DNS:keycloak.${LAB_DOMAIN},IP:${BASTION_HOST}\" -ext \"BC=ca:true\" ; \
    mv /usr/local/keycloak/keycloak-server/conf/keycloak.conf /usr/local/keycloak/keycloak-server/conf/keycloak.conf.orig ; \
    mkdir -p /usr/local/keycloak/home ; \
    groupadd keycloak ; \
    useradd -g keycloak -d /usr/local/keycloak/home keycloak"
  echo "keycloak.${LAB_DOMAIN}.           IN      A      ${BASTION_HOST}" | ${SSH} root@${EDGE_ROUTER} "cat >> /data/bind/db.${LAB_DOMAIN}"
  ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
  ${SCP} ${PI_WORK_DIR}/keycloak.conf root@${BASTION_HOST}:/usr/local/keycloak/keycloak-server/conf/keycloak.conf
  ${SCP} ${PI_WORK_DIR}/keycloak root@${BASTION_HOST}:/etc/init.d/keycloak
  ${SSH} root@${BASTION_HOST} "chown -R keycloak:keycloak /usr/local/keycloak ; chmod 750 /etc/init.d/keycloak ; /etc/init.d/keycloak enable"
}

function installApicurio() {

cat <<EOF > ${PI_WORK_DIR}/apicurio
#!/bin/sh /etc/rc.common

START=99
STOP=80
SERVICE_USE_PID=0

start() {
  service_start /usr/bin/su - apicurio -c 'PATH=/usr/local/java-11-openjdk/bin:${PATH} /usr/local/apicurio/apicurio-studio/bin/standalone.sh -c standalone-apicurio.xml -Djboss.bind.address=${BASTION_HOST} -Djboss.socket.binding.port-offset=1000 -Dapicurio.kc.auth.rootUrl="https://keycloak.${LAB_DOMAIN}:7443" -Dapicurio.kc.auth.realm="apicurio" -Dapicurio-ui.editing.url="wss://apicurio.${LAB_DOMAIN}:9443/api-editing" -Dapicurio-ui.hub-api.url="https://apicurio.${LAB_DOMAIN}:9443/api-hub" -Dapicurio-ui.url="https://apicurio.${LAB_DOMAIN}:9443/studio" > /dev/null 2>&1 &'
}

restart() {
  /usr/bin/su - apicurio -c 'kill \$(ps -x | grep apicurio | grep java | cut -d" " -f2)'
  service_start /usr/bin/su - apicurio -c 'PATH=/usr/local/java-11-openjdk/bin:${PATH} /usr/local/apicurio/apicurio-studio/bin/standalone.sh -c standalone-apicurio.xml -Djboss.bind.address=${BASTION_HOST} -Djboss.socket.binding.port-offset=1000 -Dapicurio.kc.auth.rootUrl="https://keycloak.${LAB_DOMAIN}:7443" -Dapicurio.kc.auth.realm="apicurio" -Dapicurio-ui.editing.url="wss://apicurio.${LAB_DOMAIN}:9443/api-editing" -Dapicurio-ui.hub-api.url="https://apicurio.${LAB_DOMAIN}:9443/api-hub" -Dapicurio-ui.url="https://apicurio.${LAB_DOMAIN}:9443/studio" > /dev/null 2>&1 &'
}

stop() {
   /usr/bin/su - apicurio -c 'kill \$(ps -x | grep apicurio | grep java | cut -d" " -f2)'
}
EOF

  if [[ ${LATEST} == "true" ]]
  then
    APICURIO_VER=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/Apicurio/apicurio-studio/releases/latest))
    yq e ".apicurio-version = \"${APICURIO_VER}\"" -i ${LAB_CONFIG_FILE}
  fi
  APICURIO_VER=$(yq e ".apicurio-version" ${LAB_CONFIG_FILE})
  ${SCP} ${PI_WORK_DIR}/apicurio root@${BASTION_HOST}:/etc/init.d/apicurio
  ${SSH} root@${BASTION_HOST} "mkdir -p /usr/local/apicurio/home ; \
    cd /usr/local/apicurio ; \
    wget -O apicurio-studio-${APICURIO_VER}-quickstart.zip https://github.com/Apicurio/apicurio-studio/releases/download/${APICURIO_VER}/apicurio-studio-${APICURIO_VER}-quickstart.zip ; \
    unzip apicurio-studio-${APICURIO_VER}-quickstart.zip ; \
    ln -s apicurio-studio-${APICURIO_VER} apicurio-studio ; \
    rm -f apicurio-studio-${APICURIO_VER}-quickstart.zip ; \
    cat /usr/local/apicurio/apicurio-studio/standalone/configuration/standalone-apicurio.xml | grep -v apicurio.kc.auth > /tmp/standalone-apicurio.xml ; \
    mv /usr/local/apicurio/apicurio-studio/standalone/configuration/standalone-apicurio.xml /usr/local/apicurio/apicurio-studio/standalone/configuration/standalone-apicurio.xml.orig ; \
    mv /tmp/standalone-apicurio.xml /usr/local/apicurio/apicurio-studio/standalone/configuration/standalone-apicurio.xml ; \
    sed -i \"s|generate-self-signed-certificate-host=\\\"localhost\\\"||g\" /usr/local/apicurio/apicurio-studio/standalone/configuration/standalone-apicurio.xml ; \
    /usr/local/java-11-openjdk/bin/keytool -genkeypair -keystore /usr/local/apicurio/apicurio-studio/standalone/configuration/application.keystore -deststoretype pkcs12 -storepass password -keypass password -alias server -keyalg RSA -keysize 4096 -validity 5000 -dname \"CN=apicurio.${LAB_DOMAIN}, OU=okd4-lab, O=okd4-lab, L=City, ST=State, C=US\" -ext \"SAN=DNS:apicurio.${LAB_DOMAIN},IP:${BASTION_HOST}\" -ext \"BC=ca:true\" ; \
    groupadd apicurio ; \
    useradd -g apicurio -d /usr/local/apicurio/home apicurio ; \
    chown -R apicurio:apicurio /usr/local/apicurio ; \
    chmod 750 /etc/init.d/apicurio ; \
    /etc/init.d/apicurio enable"
  echo "apicurio.${LAB_DOMAIN}.           IN      A      ${BASTION_HOST}" | ${SSH} root@${EDGE_ROUTER} "cat >> /data/bind/db.${LAB_DOMAIN}"
  ${SSH} root@${EDGE_ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
}
