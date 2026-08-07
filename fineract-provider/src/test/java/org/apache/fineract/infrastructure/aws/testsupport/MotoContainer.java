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
package org.apache.fineract.infrastructure.aws.testsupport;

import java.net.URI;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.utility.DockerImageName;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.CreateBucketRequest;

/**
 * Testcontainers wrapper around the {@code motoserver/moto} image, the standalone HTTP server implementation of the
 * moto AWS mock. moto serves every AWS API from a single port using path-style addressing, so S3 clients pointed at it
 * must enable {@code forcePathStyle}.
 * <p>
 * This is a test-only utility used by the Phase 3 AWS-migration tests to exercise the production S3 content store and
 * the default-credential chain without touching real AWS.
 */
public final class MotoContainer extends GenericContainer<MotoContainer> {

    public static final String DEFAULT_IMAGE = "motoserver/moto:latest";
    public static final int MOTO_PORT = 5000;
    public static final String REGION = "us-east-1";
    /** Throwaway credentials; moto accepts any non-blank value. */
    public static final String ACCESS_KEY = "moto";
    public static final String SECRET_KEY = "moto";

    public MotoContainer() {
        this(DEFAULT_IMAGE);
    }

    public MotoContainer(String image) {
        super(DockerImageName.parse(image));
        withEnv("MOTO_PORT", String.valueOf(MOTO_PORT));
        withExposedPorts(MOTO_PORT);
        waitingFor(Wait.forHttp("/moto-api/").forPort(MOTO_PORT).forStatusCode(200));
    }

    /** Endpoint override to hand to any AWS SDK v2 client, e.g. {@code http://localhost:32768}. */
    public String getEndpoint() {
        return "http://" + getHost() + ":" + getMappedPort(MOTO_PORT);
    }

    public StaticCredentialsProvider credentialsProvider() {
        return StaticCredentialsProvider.create(AwsBasicCredentials.create(ACCESS_KEY, SECRET_KEY));
    }

    /** An S3 client wired for moto: endpoint override, path-style addressing and throwaway static credentials. */
    public S3Client newS3Client() {
        return S3Client.builder().endpointOverride(URI.create(getEndpoint())).forcePathStyle(true).region(Region.of(REGION))
                .credentialsProvider(credentialsProvider()).build();
    }

    /** Creates an S3 bucket in moto during test setup. */
    public void createBucket(String bucketName) {
        try (S3Client s3 = newS3Client()) {
            s3.createBucket(CreateBucketRequest.builder().bucket(bucketName).build());
        }
    }
}
