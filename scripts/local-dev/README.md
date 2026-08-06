# Local development setup

Runs Fineract locally against PostgreSQL, with the external systems it talks to replaced by
local mocks (S3 via LocalStack, OAuth2 issuer via mock-oauth2-server).

Requirements: JDK 21, Docker.

## 1. Start the backing services

```bash
docker run -d --name fineract-postgres -p 5432:5432 \
  -e POSTGRES_USER=root -e POSTGRES_PASSWORD=postgres postgres:17

# Mock S3 used by report export
docker run -d --name localstack -p 4566:4566 localstack/localstack:2.1
docker exec localstack awslocal s3api create-bucket --bucket fineract-reports

# Mock OAuth2 issuer (only needed when oauth2 security is enabled, e.g. :oauth2-tests:test)
docker run -d --name mock-oauth2-server -p 9000:9000 \
  -e SERVER_PORT=9000 \
  -e JSON_CONFIG='{ "interactiveLogin": true, "httpServer": "NettyWrapper", "tokenCallbacks": [ { "issuerId": "auth/realms/fineract", "tokenExpiry": 120, "requestMappings": [{ "requestParam": "scope", "match": "fineract", "claims": { "sub": "mifos", "scope": [ "test" ] } } ] } ] }' \
  ghcr.io/navikt/mock-oauth2-server:3.0.1
```

## 2. Create the databases

```bash
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
./gradlew createPGDB -PdbName=fineract_tenants
./gradlew createPGDB -PdbName=fineract_default
```

## 3. Build and run

```bash
source local-dev.env
./gradlew clean bootJar                       # or: ./gradlew :fineract-provider:devRun
curl --insecure https://localhost:8443/fineract-provider/actuator/health
```

Liquibase migrations run on startup; the `test` Spring profile loads the demo/reference data.

## 4. Seed mock data

```bash
./scripts/local-dev/seed-mock-data.sh
```

## Tests

```bash
./gradlew test -PdbType=postgresql \
  -x :integration-tests:test -x :oauth2-tests:test -x :twofactor-tests:test -x :fineract-e2e-tests-runner:test
```

The excluded suites need a deployed server (Cargo/Tomcat WAR or a running instance); run them
separately, always with `-PdbType=postgresql`, e.g. `./gradlew :oauth2-tests:test -PdbType=postgresql`.

## Note on Maven Central rate limiting

Some networks rate-limit `repo.maven.apache.org` (HTTP 429). If dependency resolution fails that
way, add a Gradle init script (`~/.gradle/init.gradle`) preferring the Google-hosted mirror
`https://maven-central.storage-download.googleapis.com/maven2`.
