function createQuarkusProject() {

  GIT_API=${GIT_API:-https://api.github.com/user/repos}
  GIT_KEYS=${GIT_KEYS:-${HOME}/.git_token}
  
  for i in "$@"
  do
    case $i in
      -p=*|--project=*)
        PROJECT="${i#*=}"
      ;;
      -g=*|--group-id=*)
        GROUP_ID="${i#*=}"
      ;;
      -q=*|--quarkus-ver=*)
        QUARKUS_VERSION="${i#*=}"
      ;;
      -u=*|--git-url=*)
        GIT_URL="${i#*=}"
      ;;
      -o=*|--git-org=*)
        GIT_API="https://api.github.com/orgs/${i#*=}/repos"
      ;;
    esac
  done

  JAVA_VER=${JAVA_VER:-17}

  quarkus create app --maven --java=${JAVA_VER} --no-wrapper --no-code --package-name=${GROUP_ID}.${PROJECT} ${GROUP_ID}:${PROJECT}:0.1
  
  cd ${PROJECT}
  quarkus ext add quarkus-resteasy-jackson quarkus-config-yaml quarkus-rest-client quarkus-smallrye-health
  touch README.md
  mkdir -p ./src/test/java/${GROUP_ID//.//}/${PROJECT}
  touch ./src/test/java/${GROUP_ID//.//}/.gitignore
  mkdir -p ./src/main/java/${GROUP_ID//.//}/${PROJECT}/{aop,api,dto,colaborators,event,mapper,model,service}
  touch ./src/main/java/${GROUP_ID//.//}/${PROJECT}/{aop,api,dto,colaborators,event,mapper,model,service}/.gitignore
  mkdir -p ./src/main/resources/META-INF/resources
  touch ./src/main/resources/META-INF/resources/.gitignore
  touch ./src/main/resources/application.yaml
  gitInit ${PROJECT}
}

function gitInit(){
    local project=${1}
    gitIgnore
    git init
    git add .
    git commit -m "create repo"
    curl -u ${GIT_USER}:${ACCESS_TOKEN} -X POST ${GIT_API} -d "{\"name\":\"${project}\",\"private\":false}"
    git remote add origin ${GIT_URL}/${project}.git
    git branch -M main
    git push -u origin main
}

function gitIgnore() {
cat << EOF > .gitignore
target/
Dockerfile

### STS ###
.apt_generated
.classpath
.factorypath
.project
.settings
.springBeans
.sts4-cache

### IntelliJ IDEA ###
.idea
*.iws
*.iml
*.ipr

### NetBeans ###
/nbproject/private/
/nbbuild/
/dist/
/nbdist/
/.nb-gradle/
build/

### VS Code ###
.vscode/
.mvn/
mvnw
mvnw.cmd

### MacOS ###
.DS_Store
EOF
}