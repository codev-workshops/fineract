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

import jakarta.servlet.http.HttpServletRequest;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.boot.actuate.autoconfigure.security.servlet.ManagementWebSecurityAutoConfiguration;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration;
import org.springframework.boot.autoconfigure.jdbc.DataSourceTransactionManagerAutoConfiguration;
import org.springframework.boot.autoconfigure.orm.jpa.HibernateJpaAutoConfiguration;
import org.springframework.boot.autoconfigure.security.servlet.SecurityAutoConfiguration;
import org.springframework.boot.autoconfigure.security.servlet.SecurityFilterAutoConfiguration;
import org.springframework.boot.autoconfigure.security.servlet.UserDetailsServiceAutoConfiguration;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Import;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.support.ServletUriComponentsBuilder;

/**
 * Phase 3 - Scenario 6: ALB-terminated-TLS / forwarded-headers behaviour.
 * <p>
 * Boots an embedded servlet container with {@code server.ssl.enabled=false} (TLS terminates at the ALB) and
 * {@code server.forward-headers-strategy=framework} - the same setting used in the Fineract application.properties -
 * then sends {@code X-Forwarded-Proto}/{@code X-Forwarded-Host}/{@code X-Forwarded-For} over plain HTTP and asserts the
 * app both serves correctly over HTTP and reconstructs request URLs / client information from the forwarded headers.
 * This validates the ECS-behind-ALB topology.
 * <p>
 * A minimal self-contained application context is used so the test exercises only the forwarded-header machinery,
 * independent of the full Fineract wiring.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, classes = ForwardedHeadersTlsTerminationTest.ForwardedHeadersTestApp.class, properties = {
        "server.ssl.enabled=false", "server.forward-headers-strategy=framework", "spring.main.web-application-type=servlet",
        "server.servlet.context-path=", "management.endpoints.enabled-by-default=false" })
class ForwardedHeadersTlsTerminationTest {

    @LocalServerPort
    private int port;

    private final TestRestTemplate restTemplate = new TestRestTemplate();

    @Test
    void servesOverPlainHttpAndHonorsForwardedHeaders() {
        HttpHeaders headers = new HttpHeaders();
        headers.add("X-Forwarded-Proto", "https");
        headers.add("X-Forwarded-Host", "fineract.example.org");
        headers.add("X-Forwarded-Port", "443");
        headers.add("X-Forwarded-For", "203.0.113.7");

        // Plain HTTP request to the embedded container (TLS terminated at the "ALB").
        ResponseEntity<String> raw = restTemplate.exchange("http://localhost:" + port + "/whereami", HttpMethod.GET,
                new HttpEntity<>(headers), String.class);
        assertThat(raw.getStatusCode()).as("body was: %s", raw.getBody()).isEqualTo(HttpStatus.OK);

        ResponseEntity<Map> response = restTemplate.exchange("http://localhost:" + port + "/whereami", HttpMethod.GET,
                new HttpEntity<>(headers), Map.class);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        Map<?, ?> body = response.getBody();
        assertThat(body).isNotNull();
        // forward-headers-strategy=framework reconstructs the externally visible URL from the forwarded headers.
        assertThat((String) body.get("requestUrl")).startsWith("https://fineract.example.org");
        assertThat(body.get("scheme")).isEqualTo("https");
        assertThat(body.get("serverName")).isEqualTo("fineract.example.org");
        assertThat(body.get("remoteAddr")).isEqualTo("203.0.113.7");
    }

    @SpringBootApplication(exclude = { DataSourceAutoConfiguration.class, DataSourceTransactionManagerAutoConfiguration.class,
            HibernateJpaAutoConfiguration.class, SecurityAutoConfiguration.class, SecurityFilterAutoConfiguration.class,
            UserDetailsServiceAutoConfiguration.class, ManagementWebSecurityAutoConfiguration.class })
    @Import(WhereAmIController.class)
    static class ForwardedHeadersTestApp {}

    @RestController
    static class WhereAmIController {

        @GetMapping("/whereami")
        Map<String, String> whereAmI(HttpServletRequest request) {
            return Map.of("requestUrl", ServletUriComponentsBuilder.fromCurrentRequest().build().toUriString(), "scheme",
                    request.getScheme(), "serverName", request.getServerName(), "remoteAddr", request.getRemoteAddr());
        }
    }
}
