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
package org.apache.fineract.infrastructure.aws;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.Map;
import org.apache.fineract.infrastructure.core.config.FineractProperties;
import org.apache.fineract.infrastructure.core.service.database.DatabasePasswordEncryptor;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.BeanCreationException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.support.PropertySourcesPlaceholderConfigurer;
import org.springframework.core.env.MapPropertySource;

/**
 * Phase 3 - Scenario 7: secrets-injection boot behaviour.
 * <p>
 * The ECS task {@code secrets} binding surfaces AWS Secrets Manager values as environment variables inside the
 * container, which Fineract references as bare placeholders (e.g. {@code ${FINERACT_DEFAULT_TENANTDB_PWD}},
 * {@code ${FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD}}) with <em>no</em> insecure fallback default after the Phase 1
 * hardening. This test proves both halves of that contract:
 * <ul>
 * <li>positive: when the required secrets are supplied (as env-style properties), resolution succeeds cleanly;</li>
 * <li>negative: when a required secret is absent, resolution fails fast rather than silently booting with a blank or
 * default value.</li>
 * </ul>
 * It exercises the real Phase 1 fail-fast seam in {@link DatabasePasswordEncryptor} for the master password, and the
 * Spring placeholder machinery (as used by application.properties) for an injected DB password.
 */
class SecretsInjectionBootTest {

    /** Master password supplied - mirrors FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD coming from the task secrets. */
    @Test
    void masterPasswordProvidedResolvesCleanly() {
        DatabasePasswordEncryptor encryptor = new DatabasePasswordEncryptor(propertiesWithMasterPassword("master-from-secrets-manager"));

        String hash = encryptor.getMasterPasswordHash();
        assertThat(hash).isNotBlank();
        assertThat(encryptor.isMasterPasswordHashValid(hash)).isTrue();
    }

    /** Master password absent everywhere - must fail fast, not fall back to an insecure default. */
    @Test
    void missingMasterPasswordFailsFast() {
        DatabasePasswordEncryptor encryptor = new DatabasePasswordEncryptor(propertiesWithMasterPassword(null));

        assertThatThrownBy(encryptor::getMasterPasswordHash).isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("master password is not configured");
    }

    /** An unresolved ${...} placeholder (env var missing) must also fail fast rather than be treated as a value. */
    @Test
    void unresolvedPlaceholderMasterPasswordFailsFast() {
        DatabasePasswordEncryptor encryptor = new DatabasePasswordEncryptor(
                propertiesWithMasterPassword("${FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD}"));

        assertThatThrownBy(encryptor::getMasterPasswordHash).isInstanceOf(IllegalStateException.class);
    }

    /** A required secret provided via an env-style property source resolves and the context starts cleanly. */
    @Test
    void requiredSecretInjectedFromEnvStartsContext() {
        try (AnnotationConfigApplicationContext context = new AnnotationConfigApplicationContext()) {
            context.getEnvironment().getPropertySources()
                    .addFirst(new MapPropertySource("ecs-task-secrets", Map.of("FINERACT_DEFAULT_TENANTDB_PWD", "db-pw-from-secrets")));
            context.register(SecretConsumingConfig.class);

            assertThatCode(context::refresh).doesNotThrowAnyException();
            assertThat(context.getBean(SecretConsumingConfig.SecretHolder.class).dbPassword).isEqualTo("db-pw-from-secrets");
        }
    }

    /** The same required secret missing must fail the context startup fast (no silent boot). */
    @Test
    void missingRequiredSecretFailsContextStartup() {
        try (AnnotationConfigApplicationContext context = new AnnotationConfigApplicationContext()) {
            context.register(SecretConsumingConfig.class);

            assertThatThrownBy(context::refresh).isInstanceOf(BeanCreationException.class)
                    .hasStackTraceContaining("Could not resolve placeholder 'FINERACT_DEFAULT_TENANTDB_PWD'");
        }
    }

    private static FineractProperties propertiesWithMasterPassword(String masterPassword) {
        FineractProperties.FineractTenantProperties tenant = new FineractProperties.FineractTenantProperties();
        tenant.setMasterPassword(masterPassword);

        // Phase 1 also removed the fallback default; leave it blank so no insecure default masks a missing secret.
        FineractProperties.FineractDatabaseProperties database = new FineractProperties.FineractDatabaseProperties();
        database.setDefaultMasterPassword("");

        FineractProperties properties = new FineractProperties();
        properties.setTenant(tenant);
        properties.setDatabase(database);
        return properties;
    }

    @Configuration
    static class SecretConsumingConfig {

        @Bean
        static PropertySourcesPlaceholderConfigurer placeholderConfigurer() {
            return new PropertySourcesPlaceholderConfigurer();
        }

        // Mirrors application.properties: a required secret placeholder with no default.
        @Bean
        SecretHolder secretHolder(@Value("${FINERACT_DEFAULT_TENANTDB_PWD}") String dbPassword) {
            return new SecretHolder(dbPassword);
        }

        static class SecretHolder {

            final String dbPassword;

            SecretHolder(String dbPassword) {
                this.dbPassword = dbPassword;
            }
        }
    }
}
