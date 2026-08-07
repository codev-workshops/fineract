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

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.Set;
import org.apache.fineract.infrastructure.aws.testsupport.MotoContainer;
import org.apache.fineract.infrastructure.core.config.ContentS3Config;
import org.apache.fineract.infrastructure.core.config.FineractProperties;
import org.apache.fineract.infrastructure.documentmanagement.command.DocumentCommand;
import org.apache.fineract.infrastructure.documentmanagement.contentrepository.S3ContentRepository;
import org.apache.fineract.infrastructure.documentmanagement.data.DocumentData;
import org.apache.fineract.infrastructure.documentmanagement.data.FileData;
import org.apache.fineract.infrastructure.documentmanagement.domain.StorageType;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import software.amazon.awssdk.services.s3.S3Client;

/**
 * Phase 3 - Scenario 2: IAM-role / {@code DefaultCredentialsProvider} credential path.
 * <p>
 * Exercises the branch in {@code ContentS3Config.getCredentialProvider} where blank access/secret keys cause
 * {@code DefaultCredentialsProvider.create()} to be used - the ECS task-role path. The {@code fineract.content.s3}
 * access/secret keys are left blank and credentials are supplied only through the standard AWS resolution chain, then a
 * real S3 round-trip is performed against moto. This proves the app works without static keys, mirroring an ECS task
 * role.
 * <p>
 * A JUnit process cannot mutate its own OS environment, so the credentials are provided here via the JVM system
 * properties {@code aws.accessKeyId}/{@code aws.secretAccessKey}/{@code aws.region}. These are resolved by the same
 * {@code DefaultCredentialsProvider} chain that reads {@code AWS_ACCESS_KEY_ID}/{@code AWS_SECRET_ACCESS_KEY}/
 * {@code AWS_REGION} on ECS (see {@code SystemPropertyCredentialsProvider} /
 * {@code EnvironmentVariableCredentialsProvider} in the chain), so the production {@code getCredentialProvider} branch
 * is what actually resolves them here.
 * <p>
 * No production credential logic is changed: because {@code ContentS3Config} already honours the explicit
 * {@code fineract.content.s3.endpoint} override regardless of the credential provider, the moto endpoint is injected
 * through configuration rather than an {@code S3ClientCustomizer} test seam.
 */
@Testcontainers
class S3DefaultCredentialsProviderMotoTest {

    private static final String BUCKET = "fineract-content-taskrole";
    private static final String CONTENT_TYPE = "text/plain";

    @Container
    private static final MotoContainer MOTO = new MotoContainer();

    private static FineractProperties properties;
    private static S3Client s3Client;

    @BeforeAll
    static void setUp() {
        // Credentials via the standard AWS chain only (no static fineract.content.s3 keys).
        System.setProperty("aws.accessKeyId", MotoContainer.ACCESS_KEY);
        System.setProperty("aws.secretAccessKey", MotoContainer.SECRET_KEY);
        System.setProperty("aws.region", MotoContainer.REGION);

        MOTO.createBucket(BUCKET);

        properties = blankCredentialS3Properties(MOTO.getEndpoint());
        s3Client = new ContentS3Config().contentS3Client(properties);
    }

    @AfterAll
    static void tearDown() {
        System.clearProperty("aws.accessKeyId");
        System.clearProperty("aws.secretAccessKey");
        System.clearProperty("aws.region");
        if (s3Client != null) {
            s3Client.close();
        }
    }

    @Test
    void roundTripWithDefaultCredentialsProvider() throws Exception {
        S3ContentRepository repository = new S3ContentRepository(s3Client, properties);

        byte[] payload = "resolved via the default credential chain".getBytes(StandardCharsets.UTF_8);
        DocumentCommand command = new DocumentCommand(Set.of(), null, "clients", 7L, "TaskRole", "taskrole.txt", (long) payload.length,
                CONTENT_TYPE, "no static keys", null);

        String location = repository.saveFile(new ByteArrayInputStream(payload), command);
        assertThat(location).isNotBlank();

        DocumentData documentData = new DocumentData(7L, "clients", 7L, "TaskRole", "taskrole.txt", (long) payload.length, CONTENT_TYPE,
                location, "no static keys", StorageType.S3.getValue());
        FileData fetched = repository.fetchFile(documentData);

        assertThat(fetched.getByteSource().read()).isEqualTo(payload);
        assertThat(fetched.contentType()).isEqualTo(CONTENT_TYPE);

        repository.deleteFile(location);
    }

    static FineractProperties blankCredentialS3Properties(String endpoint) {
        FineractProperties.FineractContentS3Properties s3 = new FineractProperties.FineractContentS3Properties();
        s3.setEnabled(true);
        s3.setBucketName(BUCKET);
        s3.setRegion(MotoContainer.REGION);
        s3.setEndpoint(endpoint);
        s3.setPathStyleAddressingEnabled(true);
        // Deliberately blank so getCredentialProvider() falls back to DefaultCredentialsProvider.create().
        s3.setAccessKey("");
        s3.setSecretKey("");

        FineractProperties.FineractContentProperties content = new FineractProperties.FineractContentProperties();
        content.setS3(s3);

        FineractProperties properties = new FineractProperties();
        properties.setContent(content);
        return properties;
    }
}
