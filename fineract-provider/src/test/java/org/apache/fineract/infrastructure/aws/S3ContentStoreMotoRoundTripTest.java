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
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Set;
import org.apache.fineract.infrastructure.aws.testsupport.MotoContainer;
import org.apache.fineract.infrastructure.core.config.ContentS3Config;
import org.apache.fineract.infrastructure.core.config.FineractProperties;
import org.apache.fineract.infrastructure.core.domain.Base64EncodedImage;
import org.apache.fineract.infrastructure.documentmanagement.command.DocumentCommand;
import org.apache.fineract.infrastructure.documentmanagement.contentrepository.ContentRepository;
import org.apache.fineract.infrastructure.documentmanagement.contentrepository.ContentRepositoryFactory;
import org.apache.fineract.infrastructure.documentmanagement.contentrepository.S3ContentRepository;
import org.apache.fineract.infrastructure.documentmanagement.data.DocumentData;
import org.apache.fineract.infrastructure.documentmanagement.data.FileData;
import org.apache.fineract.infrastructure.documentmanagement.data.ImageData;
import org.apache.fineract.infrastructure.documentmanagement.domain.StorageType;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import software.amazon.awssdk.services.s3.S3Client;

/**
 * Phase 3 - Scenario 1: S3 content-store round-trip against moto.
 * <p>
 * Boots the <em>production</em> {@link ContentS3Config} S3 client with the same settings the ECS deployment uses
 * ({@code FINERACT_CONTENT_S3_ENABLED=true}, a bucket name, an endpoint override pointed at moto, path-style addressing
 * and a region) and drives the production {@code S3ContentRepository} through a document lifecycle (save -> fetch ->
 * delete), asserting the uploaded bytes round-trip through S3 with the correct content type and length.
 * <p>
 * It also asserts that {@link ContentRepositoryFactory} selects the S3 storage type when S3 is enabled, matching the
 * document API behaviour exercised by {@code integration-tests/.../client/DocumentTest.java}.
 */
@Testcontainers
class S3ContentStoreMotoRoundTripTest {

    private static final String BUCKET = "fineract-content";
    private static final String CONTENT_TYPE = "image/jpeg";

    @Container
    private static final MotoContainer MOTO = new MotoContainer();

    private static FineractProperties properties;
    private static S3Client s3Client;

    @BeforeAll
    static void setUp() {
        MOTO.createBucket(BUCKET);

        properties = s3Properties(MOTO.getEndpoint());
        // The production config builds the S3 client from the same FineractProperties the app reads at runtime.
        s3Client = new ContentS3Config().contentS3Client(properties);
        assertNotNull(s3Client);
    }

    @AfterAll
    static void tearDown() {
        if (s3Client != null) {
            s3Client.close();
        }
    }

    @Test
    void factorySelectsS3RepositoryWhenS3Enabled() {
        ContentRepositoryFactory factory = new ContentRepositoryFactory(properties,
                List.of(new StubFileSystemRepository(), new S3ContentRepository(s3Client, properties)));

        ContentRepository repository = factory.getRepository();
        assertThat(repository.getStorageType()).isEqualTo(StorageType.S3);
    }

    @Test
    void uploadedBytesRoundTripThroughS3() throws Exception {
        S3ContentRepository repository = new S3ContentRepository(s3Client, properties);

        byte[] payload = "the quick brown fox jumps over the lazy dog".getBytes(StandardCharsets.UTF_8);
        DocumentCommand command = new DocumentCommand(Set.of(), null, "clients", 1L, "Test", "greeting.txt", (long) payload.length,
                CONTENT_TYPE, "The Description", null);

        // save -> reports the S3 storage type for the created document
        String location = repository.saveFile(new ByteArrayInputStream(payload), command);
        assertThat(location).isNotBlank();
        assertThat(repository.getStorageType()).isEqualTo(StorageType.S3);

        // fetch -> the download must equal the uploaded bytes, with the same content type and length
        DocumentData documentData = new DocumentData(1L, "clients", 1L, "Test", "greeting.txt", (long) payload.length, CONTENT_TYPE,
                location, "The Description", StorageType.S3.getValue());
        FileData fetched = repository.fetchFile(documentData);
        byte[] downloaded = fetched.getByteSource().read();

        assertThat(downloaded).isEqualTo(payload);
        assertThat(fetched.contentType()).isEqualTo(CONTENT_TYPE);
        assertThat(downloaded.length).isEqualTo(payload.length);

        // delete -> the object no longer resolves
        repository.deleteFile(location);
        assertThatThrownBy(() -> repository.fetchFile(documentData).getByteSource().read()).isInstanceOf(Exception.class);
    }

    static FineractProperties s3Properties(String endpoint) {
        FineractProperties.FineractContentS3Properties s3 = new FineractProperties.FineractContentS3Properties();
        s3.setEnabled(true);
        s3.setBucketName(BUCKET);
        s3.setRegion(MotoContainer.REGION);
        s3.setEndpoint(endpoint);
        s3.setPathStyleAddressingEnabled(true);
        s3.setAccessKey(MotoContainer.ACCESS_KEY);
        s3.setSecretKey(MotoContainer.SECRET_KEY);

        FineractProperties.FineractContentProperties content = new FineractProperties.FineractContentProperties();
        content.setS3(s3);

        FineractProperties properties = new FineractProperties();
        properties.setContent(content);
        return properties;
    }

    /** Minimal filesystem repository so the factory has a non-S3 alternative to (not) pick. */
    private static final class StubFileSystemRepository implements ContentRepository {

        @Override
        public String saveFile(InputStream toUpload, DocumentCommand documentCommand) {
            throw new UnsupportedOperationException();
        }

        @Override
        public void deleteFile(String documentPath) {
            throw new UnsupportedOperationException();
        }

        @Override
        public String saveImage(InputStream toUploadInputStream, Long resourceId, String imageName, Long fileSize) {
            throw new UnsupportedOperationException();
        }

        @Override
        public String saveImage(Base64EncodedImage base64EncodedImage, Long resourceId, String imageName) {
            throw new UnsupportedOperationException();
        }

        @Override
        public void deleteImage(String location) {
            throw new UnsupportedOperationException();
        }

        @Override
        public FileData fetchFile(DocumentData documentData) {
            throw new UnsupportedOperationException();
        }

        @Override
        public FileData fetchImage(ImageData imageData) {
            throw new UnsupportedOperationException();
        }

        @Override
        public StorageType getStorageType() {
            return StorageType.FILE_SYSTEM;
        }
    }
}
