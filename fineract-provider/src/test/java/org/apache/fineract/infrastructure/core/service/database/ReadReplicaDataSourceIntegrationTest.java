/**
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements. See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership. The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License. You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
package org.apache.fineract.infrastructure.core.service.database;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Optional;
import java.util.Properties;
import javax.sql.DataSource;
import org.apache.fineract.infrastructure.core.config.FineractProperties;
import org.apache.fineract.infrastructure.core.domain.FineractPlatformTenant;
import org.apache.fineract.infrastructure.core.domain.FineractPlatformTenantConnection;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * Phase 3 - Scenario 3: read-replica (read-only datasource) integration test.
 * <p>
 * Complements the mock-based {@code DataSourcePerTenantServiceFactoryTest} with a live boot: a primary Postgres and a
 * second Postgres acting as the read replica are started as two Testcontainers instances. The tenant connection is
 * configured with a distinct read-only endpoint (as {@code FINERACT_DEFAULT_TENANTDB_RO_*} would set) and the instance
 * runs in read-only mode ({@code fineract.mode.read-enabled=true}, write/batch off).
 * <p>
 * The test drives the production {@code DataSourcePerTenantServiceFactory.createNewDataSourceFor} through the branch
 * guarded by {@code mode.isReadOnlyMode()} and asserts the resulting datasource is read-only and points at the RO
 * endpoint, then opens a real connection to actually serve a read from the replica while a write is rejected - proving
 * the read node cannot mutate data and needs the (separate) write node.
 */
@Testcontainers
class ReadReplicaDataSourceIntegrationTest {

    private static final String MASTER_PASSWORD = "fineract";
    private static final String DB_NAME = "fineract_default";

    @Container
    private static final PostgreSQLContainer<?> PRIMARY = new PostgreSQLContainer<>("postgres:17").withDatabaseName(DB_NAME)
            .withUsername("root").withPassword("primary-pw");

    @Container
    private static final PostgreSQLContainer<?> REPLICA = new PostgreSQLContainer<>("postgres:17").withDatabaseName(DB_NAME)
            .withUsername("root").withPassword("replica-pw");

    private static FineractProperties readOnlyProperties;
    private static DatabasePasswordEncryptor encryptor;
    private static HikariDataSource masterDataSource;

    @BeforeAll
    static void setUp() throws Exception {
        // The replica serves reads: seed a table + row so a read can succeed against the RO endpoint.
        seedReadableTable(REPLICA);
        // The primary is the (separate) write node.
        seedReadableTable(PRIMARY);

        readOnlyProperties = readOnlyMode();
        encryptor = new DatabasePasswordEncryptor(readOnlyProperties);

        masterDataSource = new HikariDataSource(hikariConfigFor(PRIMARY));
    }

    @AfterAll
    static void tearDown() {
        if (masterDataSource != null) {
            masterDataSource.close();
        }
    }

    @Test
    void readOnlyModeCreatesReadOnlyDataSourcePointingAtReplica() throws Exception {
        DataSourcePerTenantServiceFactory factory = new DataSourcePerTenantServiceFactory(templateHikariConfig(), readOnlyProperties, null,
                masterDataSource, new HikariDataSourceFactory(), encryptor, Optional.empty());

        FineractPlatformTenantConnection connection = tenantConnection();
        FineractPlatformTenant tenant = FineractPlatformTenant.builder().id(1L).tenantIdentifier("default").name("Default")
                .timezoneId("Asia/Kolkata").connection(connection).build();

        DataSource dataSource = factory.createNewDataSourceFor(tenant, connection);

        assertThat(dataSource).isInstanceOf(HikariDataSource.class);
        HikariDataSource hikari = (HikariDataSource) dataSource;
        assertThat(hikari.isReadOnly()).isTrue();
        // Points at the RO endpoint (replica), not the primary.
        assertThat(hikari.getJdbcUrl()).contains(REPLICA.getHost() + ":" + REPLICA.getFirstMappedPort());
        assertThat(hikari.getJdbcUrl()).doesNotContain(":" + PRIMARY.getFirstMappedPort() + "/");

        try (Connection connection1 = hikari.getConnection()) {
            assertThat(connection1.isReadOnly()).isTrue();

            // Serves a read from the replica.
            try (Statement statement = connection1.createStatement();
                    ResultSet rs = statement.executeQuery("SELECT name FROM demo_client")) {
                assertThat(rs.next()).isTrue();
                assertThat(rs.getString("name")).isEqualTo("Alice");
            }

            // Rejects a write - the read node cannot mutate; writes need the write node.
            try (Statement statement = connection1.createStatement()) {
                assertThatThrownBy(() -> statement.executeUpdate("INSERT INTO demo_client(name) VALUES ('Mallory')"))
                        .isInstanceOf(SQLException.class);
            }
        } finally {
            hikari.close();
        }
    }

    private static void seedReadableTable(PostgreSQLContainer<?> container) throws SQLException {
        try (Connection connection = java.sql.DriverManager.getConnection(container.getJdbcUrl(), container.getUsername(),
                container.getPassword()); Statement statement = connection.createStatement()) {
            statement.execute("CREATE TABLE IF NOT EXISTS demo_client (id SERIAL PRIMARY KEY, name VARCHAR(64))");
            statement.execute("INSERT INTO demo_client(name) VALUES ('Alice')");
        }
    }

    /**
     * A plain (writable) Hikari datasource used as the master/tenants datasource so toProtocol() resolves postgresql.
     */
    private static HikariConfig hikariConfigFor(PostgreSQLContainer<?> container) {
        HikariConfig config = new HikariConfig();
        config.setDriverClassName("org.postgresql.Driver");
        config.setJdbcUrl(container.getJdbcUrl());
        config.setUsername(container.getUsername());
        config.setPassword(container.getPassword());
        config.setMaximumPoolSize(2);
        return config;
    }

    /** The HikariConfig template the factory copies driver/test-query/autocommit settings from. */
    private static HikariConfig templateHikariConfig() {
        HikariConfig config = new HikariConfig();
        config.setDriverClassName("org.postgresql.Driver");
        // A dummy jdbcUrl keeps HikariConfig happy; the factory never connects with the template itself.
        config.setJdbcUrl(PRIMARY.getJdbcUrl());
        config.setUsername(PRIMARY.getUsername());
        config.setPassword(PRIMARY.getPassword());
        config.setAutoCommit(true);
        config.setDataSourceProperties(new Properties());
        return config;
    }

    private static FineractPlatformTenantConnection tenantConnection() {
        return FineractPlatformTenantConnection.builder().connectionId(1L)
                // write (primary) endpoint
                .schemaServer(PRIMARY.getHost()).schemaServerPort(String.valueOf(PRIMARY.getFirstMappedPort())).schemaName(DB_NAME)
                .schemaUsername(PRIMARY.getUsername()).schemaPassword(encryptor.encrypt(PRIMARY.getPassword()))
                // read-only (replica) endpoint
                .readOnlySchemaServer(REPLICA.getHost()).readOnlySchemaServerPort(String.valueOf(REPLICA.getFirstMappedPort()))
                .readOnlySchemaName(DB_NAME).readOnlySchemaUsername(REPLICA.getUsername())
                .readOnlySchemaPassword(encryptor.encrypt(REPLICA.getPassword()))
                // pgjdbc enforces read-only for every statement (incl. autocommit) with readOnlyMode=always.
                .readOnlySchemaConnectionParameters("readOnlyMode=always") //
                .initialSize(1).maxActive(2).validationInterval(3000L) //
                .masterPasswordHash(encryptor.getMasterPasswordHash()).build();
    }

    private static FineractProperties readOnlyMode() {
        FineractProperties.FineractModeProperties mode = new FineractProperties.FineractModeProperties();
        mode.setReadEnabled(true);
        mode.setWriteEnabled(false);
        mode.setBatchWorkerEnabled(false);
        mode.setBatchManagerEnabled(false);

        FineractProperties.FineractConfigProperties config = new FineractProperties.FineractConfigProperties();
        config.setMinPoolSize(-1);
        config.setMaxPoolSize(-1);

        FineractProperties.FineractTenantProperties tenant = new FineractProperties.FineractTenantProperties();
        tenant.setMasterPassword(MASTER_PASSWORD);
        tenant.setEncryption(DatabasePasswordEncryptor.DEFAULT_ENCRYPTION);
        tenant.setConfig(config);

        // getMasterPassword() falls back to the database default via Optional.orElse, which is evaluated eagerly.
        FineractProperties.FineractDatabaseProperties database = new FineractProperties.FineractDatabaseProperties();
        database.setDefaultMasterPassword(MASTER_PASSWORD);

        FineractProperties properties = new FineractProperties();
        properties.setMode(mode);
        properties.setTenant(tenant);
        properties.setDatabase(database);
        return properties;
    }
}
